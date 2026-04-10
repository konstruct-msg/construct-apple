import Foundation

/// Central registry for all network-related timing constants.
/// Keep this as the single source of truth to avoid drift across subsystems.
enum NetworkTiming {

    // MARK: - Generic / HTTP

    enum HTTP {
        static let connectionTimeout: TimeInterval = 30.0
        static let messageSendNetworkTimeout: TimeInterval = 60.0
    }

    // MARK: - Messaging / Queue

    enum Messaging {
        static let messageAckTimeout: TimeInterval = 15.0
        static let messageSendTimeout: TimeInterval = 20.0
        static let queueCheckInterval: TimeInterval = 5.0
    }

    // MARK: - Long Polling

    enum LongPolling {
        static let fullTimeoutSeconds: Int = 30
        static let minimalTimeoutSeconds: Int = 30
        static let minimalPostPollDelaySeconds: TimeInterval = 60
        static let successJitterMinMs: UInt64 = 1_000
        static let successJitterMaxMs: UInt64 = 3_000
        static let timeout: TimeInterval = 65.0
        static let resourceTimeout: TimeInterval = 70.0
    }

    // MARK: - WebSocket

    enum WebSocket {
        static let pingInterval: TimeInterval = 25.0
        static let reconnectBaseDelay: TimeInterval = 2.0
        static let reconnectMaxDelay: TimeInterval = 30.0
        static let backgroundFetchTimeout: TimeInterval = 15.0
        static let backgroundFetchRequestTimeout: TimeInterval = 15.0
        static let backgroundFetchResourceTimeout: TimeInterval = 20.0
        static let authenticationDelay: TimeInterval = 0.5
        static let messageQueueFlushDelay: TimeInterval = 0.1
    }

    // MARK: - gRPC

    enum GRPC {
        // Routing failover ("happy eyeballs")
        static let fastFallbackDirectTimeout: TimeInterval = 4.0
        static let streamOpenAcceptTimeout: TimeInterval = 2.5
        static let streamOpenAcceptPollInterval: TimeInterval = 0.05

        // Transport keepalive (HTTP/2)
        static let maxIdleTimeSeconds: Int64 = 300
        static let keepaliveTimeDirectSeconds: Int64 = 30
        static let keepaliveTimeIceSeconds: Int64 = 25
        static let keepaliveTimeoutSeconds: Int64 = 10

        enum Timeouts {
            // Authentication
            static let powChallenge: TimeInterval = 15
            static let registerDevice: TimeInterval = 20
            static let authenticateDevice: TimeInterval = 20
            static let refreshToken: TimeInterval = 15
            static let logout: TimeInterval = 20
            static let recovery: TimeInterval = 30

            // Device linking
            static let initiateDeviceLink: TimeInterval = 15
            static let confirmDeviceLink: TimeInterval = 30
            static let listDevices: TimeInterval = 20
            static let revokeDevice: TimeInterval = 15

            // Messaging (interactive)
            static let sendMessage: TimeInterval = 20
            static let editMessage: TimeInterval = 20
            static let endSession: TimeInterval = 20

            // Messaging (background/service)
            static let getPendingMessages: TimeInterval = 30

            // Key service (session init / rotations)
            static let getPreKeyBundle: TimeInterval = 20
            static let getPreKeyBundles: TimeInterval = 25
            static let uploadPreKeys: TimeInterval = 30
            static let getPreKeyCount: TimeInterval = 15
            static let rotateSignedPreKey: TimeInterval = 20
            static let getIdentityKey: TimeInterval = 15

            // User / invites / trust
            static let getUserProfile: TimeInterval = 15
            static let updateUserProfile: TimeInterval = 15
            static let usernameAvailability: TimeInterval = 15
            static let deleteAccount: TimeInterval = 30
            static let blockUser: TimeInterval = 15
            static let unblockUser: TimeInterval = 15

            static let generateInvite: TimeInterval = 15
            static let acceptInvite: TimeInterval = 20
            static let listInvites: TimeInterval = 15
            static let revokeInvite: TimeInterval = 15

            static let reportSpam: TimeInterval = 15
            static let getTrustStatus: TimeInterval = 15
            static let checkSendPermission: TimeInterval = 15

            // Notifications
            static let registerDeviceToken: TimeInterval = 20
            static let registerVoipToken: TimeInterval = 20
            static let unregisterVoipToken: TimeInterval = 15
            static let unregisterDeviceToken: TimeInterval = 15

            // Media (streaming)
            static let downloadMedia: TimeInterval = 180
            static let uploadMedia: TimeInterval = 300

            // Calls (signaling)
            static let getTurnCredentials: TimeInterval = 15
            static let initiateCall: TimeInterval = 20
        }
    }

    // MARK: - ICE

    enum ICE {
        static let relayCooldown: TimeInterval = 60.0
        static let proxyReadyWaitTimeout: TimeInterval = 2.0
        static let onDemandStartJoinTimeout: TimeInterval = 5.0
        static let onDemandStartJoinPollInterval: TimeInterval = 0.1
        static let relayLatencyProbeTimeout: TimeInterval = 2.0
        static let certFetchTimeoutHTTPS: TimeInterval = 8.0
        /// Short RPC timeout for an unverified ICE relay. Catches DPI-blocked obfs4
        /// tunnels without making the user wait 15–30s for the full RPC deadline.
        static let unverifiedRelayTimeout: TimeInterval = 5.0

        // Happy Eyeballs — transparent failover
        /// After the first reachable relay probe result arrives, wait this long for
        /// additional results before proceeding with the sorted order.
        /// Prevents waiting for unreachable endpoints (e.g. AMS blocked in RU)
        /// when a relay has already responded.
        static let sortByLatencyEarlyExitDelay: TimeInterval = 0.3
        /// Stagger between starting the direct gRPC leg and the ICE leg
        /// in the 3-way happy-eyeballs race. Direct always starts first.
        static let happyEyeballsICEStaggerMs: UInt64 = 250
        /// Stagger between starting the ICE-TLS leg and the ICE-plain (relay) leg.
        static let happyEyeballsRelayStaggerMs: UInt64 = 200
    }

    // MARK: - Stream

    enum Stream {
        static let heartbeatInterval: TimeInterval = 25
        static let watchdogMinRestartInterval: TimeInterval = 30
        static let maxRetryDelay: TimeInterval = 60
        static let cleanEndReconnectDelay: TimeInterval = 3
        static let backoffBaseDelay: TimeInterval = 2
        static let fetchMissedMessagesWallClockCap: TimeInterval = 3
    }

    // MARK: - Media

    enum Media {
        static let retryDelaysNs: [UInt64] = [3_000_000_000, 6_000_000_000]
    }

    // MARK: - WebRTC

    enum WebRTC {
        static let turnCredentialsSkewSeconds: TimeInterval = 60
    }

    // MARK: - Calls (signaling / UI)

    enum Calls {
        static let signalingKeepaliveInterval: TimeInterval = 25
        static let signalingStreamOpenAcceptTimeout: TimeInterval = 2.5
        static let endedAutoClearDelay: TimeInterval = 3
        static let audioPreferredSampleRateHz: Double = 48_000
        static let audioPreferredIOBufferDuration: TimeInterval = 0.01
    }
}
