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
import CryptoKit
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
    case failed(message: String)
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
        let keyRead = KeychainManager.shared.readDeviceSigningKey()
        let detail = "deviceId=\(idRead.description) signingKey=\(keyRead.description)"

        switch DeviceKeyAvailability.resolve(deviceId: idRead, signingKey: keyRead) {
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
              let rawSigningKey = keyRead.data else {
            // `.present` guarantees bytes; a deviceId that is not UTF-8 is corruption, and the
            // safe reading of corruption is still "do not re-register over it".
            Log.error("DeviceAuthCoordinator: device keys unusable — \(detail)", category: "Auth")
            return .keysUnreadable(detail: detail)
        }

        do {
            let timestamp = Int64(Date().timeIntervalSince1970)
            let message = "\(deviceId)\(timestamp)"
            guard let messageData = message.data(using: .utf8) else {
                return .failed(message: "encodingFailed")
            }

            let signingKeyBytes: [UInt8]
            do {
                signingKeyBytes = try CryptoManager.shared.exportSigningSecretKey()
            } catch {
                Log.info("DeviceAuthCoordinator: CryptoCore unavailable — raw Keychain key: \(error)", category: "Auth")
                signingKeyBytes = [UInt8](rawSigningKey)
            }
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(signingKeyBytes))
            let signatureData = try privateKey.signature(for: messageData)

            // allowAuthRetry: false on the client — must not recurse into refresh/device-auth.
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
            return .failed(message: "\(error)")
        }
    }
}
