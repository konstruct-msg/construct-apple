//
//  DeviceAuthCoordinator.swift
//  Construct Messenger
//
//  Single-flight device signing-key authentication. When the refresh token is
//  permanently dead, many callers hit `.unauthenticated` at once (push, VoIP,
//  stream, gRPC retry). Without coordination they each fail and log UNAUTH while
//  AuthViewModel alone re-mints tokens — push/VoIP never retry with the new session.
//

import Foundation
import GRPCCore

/// Outcome of a device-auth attempt (signing key → new access+refresh tokens).
enum DeviceAuthOutcome: Sendable {
    case success(userId: String)
    /// Both device keys are genuinely absent (`errSecItemNotFound`) — registration is correct.
    case noDeviceKeys
    /// The keys could not be read, or only some of them exist. The identity may be intact
    /// (locked device before first unlock, protected data unavailable). The caller MUST route
    /// to recovery, never to registration — see `DeviceKeyAvailability`.
    case keysUnreadable(detail: String)
    /// `overDirectTLS`: the answer came on a TLS connection to our server both before and after
    /// the call. Over VEIL the client speaks plaintext gRPC to the relay, which can forge any
    /// answer — so an answer that erases this device (`AuthViewModel.isRemovedDevice`) counts
    /// only when this is true.
    /// `refusal`: the server's reason, read as a number (`DeviceRefusal.of`); `.unspecified` when
    /// it gave none or the failure was not a refusal at all.
    case failed(message: String, overDirectTLS: Bool, refusal: Shared_Proto_Services_V1_DeviceRefusal)
}

/// Why the server refused this device, from the trailing metadata key `construct-device-refusal`
/// of an UNAUTHENTICATED status (construct-protos `DeviceRefusal`). Read as a number because a
/// client erases itself on `.removed`, and until 2026-10-06 it decided that by matching the status
/// text — the second carrier `decisions/signals-are-numbers-not-text.md` exists to remove.
enum DeviceRefusalReading {
    static let metadataKey = "construct-device-refusal"

    static func refusal(of error: any Error) -> Shared_Proto_Services_V1_DeviceRefusal {
        guard let rpc = error as? RPCError, rpc.code == .unauthenticated,
              let value = Array(rpc.metadata[stringValues: metadataKey]).first,
              let number = Int(value),
              let refusal = Shared_Proto_Services_V1_DeviceRefusal(rawValue: number)
        else { return .unspecified }
        return refusal
    }
}

/// Serializes device-auth RPCs so concurrent recovery paths share one mint.
actor DeviceAuthCoordinator {
    static let shared = DeviceAuthCoordinator()

    private var inFlight: Task<DeviceAuthOutcome, Never>?

    /// Authenticate with the local device signing key and persist new tokens.
    /// Concurrent callers join the same in-flight task.
    @discardableResult
    func authenticateIfPossible() async -> DeviceAuthOutcome {
        // Fast path: another recovery already produced a valid session.
        let alreadyValid = await MainActor.run {
            AuthSessionManager.shared.sessionToken != nil && AuthSessionManager.shared.isSessionValid
        }
        if alreadyValid {
            let uid = await MainActor.run { AuthSessionManager.shared.currentUserId ?? "" }
            if !uid.isEmpty {
                return .success(userId: uid)
            }
        }

        if let inFlight {
            return await inFlight.value
        }

        let task = Task<DeviceAuthOutcome, Never> {
            await Self.performDeviceAuth()
        }
        inFlight = task
        defer { inFlight = nil }
        return await task.value
    }

    // MARK: - Private

    @MainActor
    private static func performDeviceAuth() async -> DeviceAuthOutcome {
        let idRead = KeychainManager.shared.readDeviceID()
        let keyRead = KeychainManager.shared.readPrivateKeys()
        let detail = "deviceId=\(idRead.description) keyRecord=\(keyRead.description)"

        switch DeviceKeyAvailability.resolve(deviceId: idRead, keyRecord: keyRead) {
        case .present:
            break
        case .absent:
            Log.info("DeviceAuthCoordinator: no device keys — \(detail)", category: "Auth")
            return .noDeviceKeys
        case .unreadable:
            // Do NOT report this as "no keys": that routes to onboarding, and registering there
            // replaces an identity that is probably still on this device (2026-08-09 incident).
            Log.error("DeviceAuthCoordinator: device keys unreadable — \(detail)", category: "Auth")
            return .keysUnreadable(detail: detail)
        }

        guard let deviceId = idRead.data.flatMap({ String(data: $0, encoding: .utf8) }),
              keyRead.data != nil else {
            // `.present` guarantees bytes; a deviceId that is not UTF-8 is corruption, and the
            // safe reading of corruption is still "do not re-register over it".
            Log.error("DeviceAuthCoordinator: device keys unusable — \(detail)", category: "Auth")
            return .keysUnreadable(detail: detail)
        }

        var directBefore = false
        do {
            let timestamp = Int64(Date().timeIntervalSince1970)
            let message = "\(deviceId)\(timestamp)"
            guard let messageData = message.data(using: .utf8) else {
                return .failed(message: "encodingFailed", overDirectTLS: false, refusal: .unspecified)
            }

            // The core signs — with the orchestrator, or the key record before one exists.
            let signatureData = try CryptoManager.shared.signWithDeviceKey(messageData)

            // allowAuthRetry: false on the client — must not recurse into refresh/device-auth.
            directBefore = GRPCChannelManager.shared.veilProxyPort() == nil
            let response = try await AuthServiceClient.shared.authenticateDevice(
                deviceId: deviceId,
                timestamp: timestamp,
                signature: signatureData
            )

            let expiresInSeconds: Int
            if let expiresAt = response.expiresAt {
                expiresInSeconds = max(Int(expiresAt - Int64(Date().timeIntervalSince1970)), 0)
            } else if let expiresIn = response.expiresIn {
                expiresInSeconds = expiresIn
            } else {
                expiresInSeconds = 3600
            }

            AuthSessionManager.shared.saveTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                expiresIn: expiresInSeconds,
                userId: response.userId
            )
            AuthSessionManager.shared.resetSessionInvalidated()

            VeilProxyManager.shared.configureFromServer(cert: response.veilBridgeCert ?? "")
            Log.info(
                "DeviceAuthCoordinator: device auth OK userId=\(response.userId.prefix(8))…",
                category: "Auth"
            )
            return .success(userId: response.userId)
        } catch {
            Log.error("DeviceAuthCoordinator: device auth failed: \(error)", category: "Auth")
            let direct = directBefore && GRPCChannelManager.shared.veilProxyPort() == nil
            return .failed(
                message: "\(error)",
                overDirectTLS: direct,
                refusal: DeviceRefusalReading.refusal(of: error)
            )
        }
    }
}
