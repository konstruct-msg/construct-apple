//
//  VoIPPushManager.swift
//  Construct Messenger
//
//  PushKit VoIP token + incoming call push reception.
//  CallKit reporting is wired in CallManager (next step).
//

#if os(iOS)
import Foundation
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

    /// Raw VoIP push payload callback (e.g. for CallKit reporting).
    var onIncomingPush: (@Sendable ([AnyHashable: Any]) -> Void)?

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
                        _ = SessionManager.shared.sessionToken
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

        Log.info("📞 PushKit VoIP registry started", category: "Calls")
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
        guard SessionManager.shared.sessionToken != nil else { return }

        // If device re-registered with a new device_id, the VoIP token must be re-registered
        // so the server routes incoming call pushes to the correct device.
        let currentDeviceId = KeychainManager.shared.loadDeviceID()
        if isRegisteredWithServer && registeredDeviceId != currentDeviceId {
            Log.info("🔄 Device ID changed — invalidating VoIP registration (was: \(registeredDeviceId?.prefix(8) ?? "nil"), now: \(currentDeviceId?.prefix(8) ?? "nil"))", category: "Calls")
            isRegisteredWithServer = false
            registeredDeviceId = nil
        }

        guard let token = voipToken, !isRegisteredWithServer else { return }
        Log.info("🔄 Retrying VoIP token registration (session now available)", category: "Calls")
        await registerWithServer(token)
    }

    private func registerWithServer(_ token: String) async {
        guard SessionManager.shared.sessionToken != nil else {
            Log.info("⏸️ VoIP token registration deferred — no session yet", category: "Calls")
            return
        }

        do {
            let ok = try await NotificationServiceClient.shared.registerVoipToken(voipToken: token)
            isRegisteredWithServer = ok
            if ok { registeredDeviceId = KeychainManager.shared.loadDeviceID() }
            Log.info("📞 VoIP token registered with server: \(ok)", category: "Calls")
        } catch {
            isRegisteredWithServer = false
            Log.error("📞 VoIP token registration failed: \(error)", category: "Calls")
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

            Log.info("📞 Received VoIP token from PushKit (len=\(tokenString.count))", category: "Calls")
            Task { await registerWithServer(tokenString) }
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        Task { @MainActor in
            guard type == .voIP else { return }
            Log.info("📞 VoIP token invalidated", category: "Calls")

            voipToken = nil
            isRegisteredWithServer = false

            Task {
                do {
                    try await NotificationServiceClient.shared.unregisterVoipToken()
                } catch {
                    Log.error("📞 Failed to unregister VoIP token: \(error)", category: "Calls")
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
        Task { @MainActor in
            guard type == .voIP else { completion(); return }
            let dict = payload.dictionaryPayload
            Log.info("📞 Incoming VoIP push received (keys=\(dict.keys.count))", category: "Calls")
            onIncomingPush?(dict)
            completion()
        }
    }
}

#endif
