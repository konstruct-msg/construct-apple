//
//  VoIPPushManager.swift
//  Construct Messenger
//
//  PushKit VoIP token + incoming call push reception.
//  CallKit reporting is wired in CallManager (next step).
//

#if os(iOS)
import Foundation
import GRPCCore
import PushKit

@MainActor
@Observable
final class VoIPPushManager: NSObject {
    static let shared = VoIPPushManager()

    private(set) var voipToken: String?
    private(set) var isRegisteredWithServer: Bool = false

    /// The device_id that was active when the VoIP token was last successfully registered.
    /// If the device re-registers and gets a new device_id, the token must be re-registered.
    private var registeredDeviceId: String?

    /// Raw VoIP push payload callback. UUID is the one already reported to CallKit synchronously.
    var onIncomingPush: (@Sendable ([AnyHashable: Any], UUID) -> Void)?

    private var registry: PKPushRegistry?
    private var sessionObserverTask: Task<Void, Never>?

    private override init() {
        super.init()

        // Retry server registration once a session becomes available.
        sessionObserverTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = AuthSessionManager.shared.sessionToken
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard !Task.isCancelled else { break }
                await self.retryServerRegistrationIfNeeded()
            }
        }
    }

    func startIfEnabled() {
        guard CallsFeature.isEnabled else { return }
        guard registry == nil else { return }

        let reg = PKPushRegistry(queue: .main)
        reg.delegate = self
        reg.desiredPushTypes = [.voIP]
        registry = reg

        Log.info("PushKit VoIP registry started", category: "Calls")
    }

    func ensureTokenRegistered() async {
        guard CallsFeature.isEnabled else { return }
        guard let token = voipToken else { return }
        if !isRegisteredWithServer {
            await registerWithServer(token)
        }
    }

    private func retryServerRegistrationIfNeeded() async {
        guard CallsFeature.isEnabled else { return }
        guard AuthSessionManager.shared.sessionToken != nil else { return }
        // userId must be present — the server requires x-user-id on this RPC.
        guard AuthSessionManager.shared.currentUserId != nil else {
            Log.debug("VoIP token retry deferred — userId not yet available", category: "Calls")
            return
        }

        // If device re-registered with a new device_id, the VoIP token must be re-registered
        // so the server routes incoming call pushes to the correct device.
        let currentDeviceId = KeychainManager.shared.loadDeviceID()
        if isRegisteredWithServer && registeredDeviceId != currentDeviceId {
            Log.info("Device ID changed — invalidating VoIP registration (was: \(registeredDeviceId?.prefix(8) ?? "nil"), now: \(currentDeviceId?.prefix(8) ?? "nil"))", category: "Calls")
            isRegisteredWithServer = false
            registeredDeviceId = nil
        }

        guard let token = voipToken, !isRegisteredWithServer else { return }
        Log.info("Retrying VoIP token registration (session now available)", category: "Calls")
        await registerWithServer(token)
    }

    private func registerWithServer(_ token: String) async {
        guard AuthSessionManager.shared.sessionToken != nil else {
            Log.info("VoIP token registration deferred — no session yet", category: "Calls")
            return
        }

        for attempt in 0..<3 {
            do {
                let ok = try await NotificationServiceClient.shared.registerVoipToken(voipToken: token)
                isRegisteredWithServer = ok
                if ok { registeredDeviceId = KeychainManager.shared.loadDeviceID() }
                Log.info("VoIP token registered with server: \(ok)", category: "Calls")
                return
            } catch {
                let shouldRetry: Bool
                if let rpcError = error as? RPCError {
                    shouldRetry = rpcError.code == .unavailable || rpcError.code == .deadlineExceeded
                } else {
                    shouldRetry = false
                }
                if shouldRetry && attempt < 2 {
                    let delay = Double(attempt + 1) * 2.0
                    Log.info("VoIP token registration failed (attempt \(attempt + 1)/3), retrying in \(Int(delay))s", category: "Calls")
                    try? await Task.sleep(for: .seconds(delay))
                } else {
                    isRegisteredWithServer = false
                    Log.error("VoIP token registration failed: \(error)", category: "Calls")
                    return
                }
            }
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02.2hhx", $0) }.joined()
    }
}

extension VoIPPushManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        Task { @MainActor in
            guard type == .voIP else { return }

            let tokenString = hex(pushCredentials.token)
            if voipToken != tokenString {
                isRegisteredWithServer = false
            }
            voipToken = tokenString

            Log.info("Received VoIP token from PushKit (len=\(tokenString.count))", category: "Calls")
            Task { await registerWithServer(tokenString) }
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Task { @MainActor in
            guard type == .voIP else { return }
            Log.info("VoIP token invalidated", category: "Calls")

            voipToken = nil
            isRegisteredWithServer = false

            Task {
                do {
                    try await NotificationServiceClient.shared.unregisterVoipToken()
                } catch {
                    Log.error("Failed to unregister VoIP token: \(error)", category: "Calls")
                }
            }
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }

        let dict = payload.dictionaryPayload
        // Call metadata is nested under "construct_call" by the server
        // (ApnsPayload::voip_incoming_call). Reading it flat always missed and fell back
        // to a fresh UUID(), so the callee built its CallKit + signaling session around a
        // call_id the server never created → "Call … not found", and the caller's hangup
        // (sent under the real call_id) could never cancel the ring. Read the nested
        // object; keep the flat dict as a defensive fallback.
        let callData = (dict["construct_call"] as? [AnyHashable: Any]) ?? dict
        let callId  = (callData["call_id"]  as? String) ?? UUID().uuidString
        let callerId = (callData["caller_id"] as? String) ?? ""

        // CRITICAL: iOS 13+ terminates the app if reportNewIncomingCall is not called
        // synchronously within this delegate method. Task { @MainActor } is an async
        // dispatch and violates this contract, causing silent app termination.
        // CXProvider.reportNewIncomingCall is thread-safe and must be called here.
        let reportedUUID = CallKitProvider.shared.reportIncomingCallSync(
            callId: callId,
            callerId: callerId,
            callerName: NSLocalizedString("construct_app_name", comment: ""),
            hasVideo: false
        )

        Log.info("Incoming VoIP push — CallKit notified sync (uuid=\(reportedUUID.uuidString.prefix(8))…)", category: "Calls")

        // Dispatch remaining setup to MainActor after CallKit obligation is fulfilled.
        Task { @MainActor in
            onIncomingPush?(dict, reportedUUID)
            completion()
        }
    }
}

#endif
