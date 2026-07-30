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
    /// Read from `APSEnvironment` in Info.plist, which expands the same
    /// `$(APS_ENVIRONMENT)` build setting as the `aps-environment` entitlement — so
    /// what we report is by construction the environment APNs minted the token for.
    ///
    /// This must NOT be `#if DEBUG`: the Beta config includes Release.xcconfig
    /// (`APS_ENVIRONMENT = production`) but defines DEBUG to keep debug UI visible in
    /// TestFlight. The old check therefore registered production TestFlight tokens as
    /// `sandbox`, and the server routed them to api.sandbox.push.apple.com, where a
    /// production token is rejected as BadDeviceToken — every TestFlight push dropped.
    private var pushEnvironment: Shared_Proto_Services_V1_PushEnvironment {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "APSEnvironment") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch declared {
        case "production":
            return .production
        case "development":
            return .sandbox
        default:
            // Missing key or an unexpanded build setting — fall back to the compile-time
            // guess rather than guessing wrong silently on a target we forgot to configure.
            Log.error(
                "APSEnvironment missing from Info.plist (got \(declared ?? "nil")) — falling back to build-config default. Push may be routed to the wrong APNs endpoint.",
                category: "Notifications"
            )
            #if DEBUG
            return .sandbox
            #else
            return .production
            #endif
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
