//
//  NotificationServiceClient.swift
//  Construct Messenger
//
//  Push token registration via NotificationService.RegisterDeviceToken.
//  Envoy route: /shared.proto.services.v1.NotificationService/RegisterDeviceToken
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2


/// Why registration could not be attempted, as opposed to why it failed.
enum PushRegistrationError: Error, LocalizedError {
    /// No device id in the Keychain yet. Registering anyway used to send an empty
    /// `device_id`, which the server maps to NULL and then upserts on
    /// `(user_id, device_token_hash)` instead of `(user_id, device_id)` — creating a row
    /// that per-device registrations can never replace. It survives as a duplicate until
    /// APNs rejects it, and the sender deletes tokens on rejection.
    case deviceIdUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceIdUnavailable:
            return "Device identity is not available yet"
        }
    }
}

final class NotificationServiceClient: Sendable {
    static let shared = NotificationServiceClient()

    private init() {}

    /// The APNs environment the running binary's token actually belongs to.
    ///
    /// The signed `aps-environment` entitlement decides this, not the Info.plist declaration —
    /// see `PushEnvironmentResolver` for the pair that disagreed on 2026-08-18 and cost every
    /// push. Undecidable resolves to `.unspecified`, which the server reads as "probe both"
    /// rather than as a value to trust.
    private var pushEnvironment: Shared_Proto_Services_V1_PushEnvironment {
        let signed = PushEnvironmentResolver.apsEnvironmentFromEmbeddedProfile()
        let declared = Bundle.main.object(forInfoDictionaryKey: "APSEnvironment") as? String

        if PushEnvironmentResolver.disagree(signedEntitlement: signed, infoPlist: declared) {
            // Loud on purpose: this is the state that deletes tokens, and every reading of it
            // in isolation looks fine. A locally installed Beta build is the usual cause.
            Log.error(
                "aps-environment mismatch — signed profile says \(signed ?? "nil"), Info.plist says \(declared ?? "nil"). Trusting the signed profile; APNs does.",
                category: "Notifications"
            )
        }

        switch PushEnvironmentResolver.resolve(signedEntitlement: signed, infoPlist: declared) {
        case .sandbox:
            return .sandbox
        case .production:
            return .production
        case .unknown:
            Log.error(
                "APNs environment undecidable (profile=\(signed ?? "nil"), Info.plist=\(declared ?? "nil")) — declaring UNSPECIFIED so the server probes both.",
                category: "Notifications"
            )
            return .unspecified
        }
    }

    // MARK: - Register / Update Device Token

    /// Registers (or updates) the APNs push token with the server.
    /// Uses NotificationService.RegisterDeviceToken (canonical push endpoint).
    func registerDeviceToken(token: String) async throws -> DeviceTokenResponse {
        // Never fall back to "": an empty device_id is not "unknown device", it is a
        // different upsert key on the server. Fail here and let the caller retry once the
        // identity exists.
        guard let deviceId = KeychainManager.shared.loadDeviceID(), !deviceId.isEmpty else {
            throw PushRegistrationError.deviceIdUnavailable
        }

        let environment = pushEnvironment

        Log.info("Registering APNs token — environment: \(environment.rawValue) (\(environment == .production ? "production" : "sandbox"))", category: "Notifications")

        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.registerDeviceToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RegisterDeviceTokenRequest()
            request.deviceToken = token
            request.deviceID = deviceId
            request.provider = .apns
            request.environment = environment
            request.notificationFilter = .visibleAll

            let response = try await client.registerDeviceToken(
                request: .init(message: request)
            )

            return DeviceTokenResponse(
                success: response.success,
                message: nil
            )
        }
    }

    // MARK: - VoIP Token (CallKit)

    /// Registers (or updates) the APNs VoIP token (PushKit) used for incoming calls.
    func registerVoipToken(voipToken: String) async throws -> Bool {
        // Never fall back to "": an empty device_id is not "unknown device", it is a
        // different upsert key on the server. Fail here and let the caller retry once the
        // identity exists.
        guard let deviceId = KeychainManager.shared.loadDeviceID(), !deviceId.isEmpty else {
            throw PushRegistrationError.deviceIdUnavailable
        }
        let environment = pushEnvironment

        return try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.registerVoipToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_RegisterVoipTokenRequest()
            request.voipToken = voipToken
            request.deviceID = deviceId
            request.platform = "ios"
            request.environment = environment

            let response = try await client.registerVoipToken(request: .init(message: request))
            return response.success
        }
    }

    /// Removes the VoIP token (typically on logout or PushKit token invalidation).
    func unregisterVoipToken() async throws {
        // Never fall back to "": an empty device_id is not "unknown device", it is a
        // different upsert key on the server. Fail here and let the caller retry once the
        // identity exists.
        guard let deviceId = KeychainManager.shared.loadDeviceID(), !deviceId.isEmpty else {
            throw PushRegistrationError.deviceIdUnavailable
        }

        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.unregisterVoipToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)
            var request = Shared_Proto_Services_V1_UnregisterVoipTokenRequest()
            request.deviceID = deviceId
            _ = try await client.unregisterVoipToken(request: .init(message: request))
        }
    }

    // MARK: - Unregister Device Token

    /// Removes the push token on logout / notifications disabled.
    func unregisterDeviceToken(token: String) async throws {
        try await GRPCChannelManager.shared.performRPC(timeout: GRPCTimeouts.unregisterDeviceToken) { grpcClient in
            let client = Shared_Proto_Services_V1_NotificationService.Client(wrapping: grpcClient)

            var request = Shared_Proto_Services_V1_UnregisterDeviceTokenRequest()
            request.deviceToken = token

            _ = try await client.unregisterDeviceToken(
                request: .init(message: request)
            )
        }
    }
}
