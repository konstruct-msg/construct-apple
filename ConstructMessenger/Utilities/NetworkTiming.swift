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
        /// Timeout waiting for the stream RPC to be accepted (H2 direct).
        /// After this duration without `isConnected = true`, fast-failover to VEIL is triggered.
        static let streamOpenAcceptTimeout: TimeInterval = 2.0
        /// Separate, looser timeout when traffic is going through an VEIL proxy.
        ///
        /// Two compounding factors require a much longer window than direct H2:
        /// 1. The relay adds an obfs4/WebTunnel round-trip on top of TCP+TLS to the server.
        /// 2. gRPC server bidi-stream handlers commonly don't flush initial response headers
        ///    until the first `Send()` (or until they receive the first client heartbeat).
        ///    With our 25s client heartbeat interval, "no headers yet" is normal for ~25s on
        ///    a quiet stream — even on a healthy channel.
        ///
        /// 20s is enough to cover the first client heartbeat → server ack round-trip on slow
        /// censored networks, while still bounded enough that a truly broken stream gets caught.
        /// (Observed 2026-05-29 on RU networks: 6s was rotating healthy streams every cycle
        /// because unary RPCs were succeeding via VEIL but the stream subscribe wasn't getting
        /// initial headers within 6s.)
        static let streamOpenAcceptTimeoutVEIL: TimeInterval = 20.0
        /// Separate, shorter timeout for H3/QUIC streams on the direct path.
        /// QUIC either connects in <500ms (0-RTT) or fails within 1–1.5s (UDP blocked, no H3
        /// support). Using a tighter window here avoids waiting 2s per H3 attempt on servers
        /// that only speak H2, while still giving QUIC enough room on high-latency paths.
        static let streamOpenAcceptTimeoutH3: TimeInterval = 1.5
        /// Hard deadline for H3/QUIC stream accept.
        /// Apple's NWConnection may not honour Swift task cancellation while the QUIC
        /// handshake is in progress — the NWConnection keeps its DispatchQueue callback
        /// registered until a ~70s system timeout fires.  This task explicitly cancels
        /// the H3 runConnections() task (closing NWConnection) so the stuck streamTask
        /// fails within ~200ms instead of 70s.  Fires only when the soft 1.5s timeout
        /// (streamOpenAcceptTimeoutH3) didn't resolve the hung channel.
        static let streamOpenAcceptTimeoutH3Hard: TimeInterval = 5.0
        /// Faster timeout used when the relay is already verified (TCP/TLS/obfs4/HTTP2 are
        /// all warm). A verified relay should respond to any new RPC within one RTT (≤200ms
        /// for AMS). 0.8s is a comfortable upper bound; anything longer signals a broken tunnel.
        static let streamOpenAcceptTimeoutVerified: TimeInterval = 0.8
        /// Happy-eyeballs standby timeout: used when VEIL is pre-warmed in standby mode.
        /// If the direct stream (H3 or H2) doesn't accept within this window, the standby
        /// VEIL proxy is promoted to active routing immediately — no H3→H2→Bayesian waterfall.
        /// Matches the verified-relay window: open networks connect in <300ms, so 0.8s is
        /// a reliable signal that the direct path is DPI-blocked on this attempt.
        static let streamOpenAcceptTimeoutStandby: TimeInterval = 0.8
        static let streamOpenAcceptPollInterval: TimeInterval = 0.05

        // Transport keepalive (HTTP/2)
        // Keepalive detects dead TCP connections. On mobile, interfaces go down silently
        // (WiFi → airplane mode, VPN toggle) without a TCP RST. The sum of keepaliveTime +
        // keepaliveTimeout is the worst-case detection latency before the client gives up and
        // creates a fresh channel.
        //
        // CRITICAL: keepaliveTime MUST be longer than our stream heartbeat interval
        // (NetworkTiming.Stream.heartbeatInterval = 25s). Otherwise the HTTP/2 PING fires
        // before the first heartbeat arrives, and PING→PONG round-trip through an obfs4
        // relay can easily exceed the 3s ACK timeout — killing the channel every 8s. This
        // was the exact failure mode observed on RU networks 2026-05-29.
        //
        // Direct path: 10s ping + 5s ack = 15s detection. Fast for healthy networks.
        // VEIL path: keepalive deliberately neutered (120s ping + 30s ack = 150s detection).
        //   Observed 2026-05-29: gRPC-swift v2's keepalive timer does NOT seem to reset on
        //   outgoing DATA frames — only on incoming. With our stream-accept being slow on
        //   bidi RPCs, no inbound activity → PING fires → no ACK through obfs4+relay+TLS
        //   round-trip → connection killed every ~50s. The heartbeat-watchdog at the
        //   application layer (NetworkTiming.Stream heartbeatInterval × multiplier = ~60s)
        //   is the real dead-stream detector on the VEIL path; HTTP/2 keepalive is just a
        //   safety net for when even that doesn't fire.
        static let maxIdleTimeSeconds: Int64 = 300
        static let keepaliveTimeDirectSeconds: Int64 = 10
        static let keepaliveTimeVEILSeconds: Int64 = 120
        static let keepaliveTimeoutSeconds: Int64 = 5
        static let keepaliveTimeoutVEILSeconds: Int64 = 30

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
            // 5s was too tight for VEIL+obfs4 RU paths — server's XREAD + response
            // can routinely take 3-7s under load. The wall-clock cap (1s) on the
            // stream side gives the iOS UI snappy fallback while this longer timeout
            // lets the actual fetch complete in background.
            static let getPendingMessages: TimeInterval = 15

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

    // MARK: - VEIL

    enum VEIL {
        static let relayCooldown: TimeInterval = 60.0
        /// Time to wait for the obfs4/WebTunnel proxy to bind its local port.
        /// Increased from 10s to 15s: Russian mobile networks (ТСПУ) require
        /// longer relay handshake + NAT traversal time. 10s caused frequent
        /// "waitForProxyReady timed out" on the first connection attempt.
        static let proxyReadyWaitTimeout: TimeInterval = 15.0
        /// Shorter timeout used on WiFi where the proxy starts in <1s typically.
        /// Avoids blocking the retry loop for 15s when VEIL simply fails on a fast network.
        static let proxyReadyWaitTimeoutWiFi: TimeInterval = 3.0
        static let onDemandStartJoinTimeout: TimeInterval = 5.0
        static let onDemandStartJoinPollInterval: TimeInterval = 0.1
        static let relayLatencyProbeTimeout: TimeInterval = 2.0
        static let certFetchTimeoutHTTPS: TimeInterval = 8.0
        /// Short RPC timeout for an unverified VEIL relay. Catches DPI-blocked obfs4
        /// tunnels without making the user wait 15–30s for the full RPC deadline.
        /// 10s gives enough headroom for obfs4 handshake + TLS + first RPC on a
        /// high-latency path (Russia → AMS), while still rotating quickly if the
        /// relay is genuinely unreachable.
        static let unverifiedRelayTimeout: TimeInterval = 10.0

        // Happy Eyeballs — transparent failover
        /// After the first reachable relay probe result arrives, wait this long for
        /// additional results before proceeding with the sorted order.
        /// Prevents waiting for unreachable endpoints (e.g. AMS blocked in RU)
        /// when a relay has already responded.
        static let sortByLatencyEarlyExitDelay: TimeInterval = 0.3
        /// Stagger between starting the direct gRPC leg and the VEIL leg
        /// in the 3-way happy-eyeballs race. Direct always starts first.
        static let happyEyeballsVEILStaggerMs: UInt64 = 250
        /// Stagger between starting the VEILTLS leg and the VEIL-plain (relay) leg.
        static let happyEyeballsRelayStaggerMs: UInt64 = 200

        // Background direct probe (auto mode only)
        /// How often to probe whether direct gRPC is accessible while on VEIL.
        static let directProbeInterval: TimeInterval = 5 * 60  // 5 min
        /// TLS connection timeout for the direct probe. Short enough to not stall
        /// UX, long enough to survive high-latency networks.
        static let directProbeTimeout: TimeInterval = 4.0
        /// Debounce between step 1 (TLS) and step 2 (gRPC) of the two-step direct probe.
        /// After TLS succeeds we wait this long before making a real gRPC call.
        /// This prevents acting on a transient TLS blip.
        static let directProbeGRPCDelay: TimeInterval = 30.0
        /// Timeout for the gRPC step of the direct probe.
        static let directProbeGRPCTimeout: TimeInterval = 6.0

        // Relay latency cache
        /// EWMA smoothing factor for relay latency measurements (0 < alpha ≤ 1).
        /// alpha=0.3 gives recent samples ~30% weight while retaining 70% of history.
        static let latencyCacheEWMAAlpha: Double = 0.3
        /// Latency cache entries older than this are considered stale and re-probed.
        static let latencyCacheValidity: TimeInterval = 5 * 60  // 5 min
    }

    // MARK: - Stream

    enum Stream {
        static let heartbeatInterval: TimeInterval = 25
        static let watchdogMinRestartInterval: TimeInterval = 30
        static let maxRetryDelay: TimeInterval = 60
        static let cleanEndReconnectDelay: TimeInterval = 3
        static let backoffBaseDelay: TimeInterval = 2
        /// Wall-clock cap for fetchMissedMessages before the stream opens.
        /// Reduced from 1.5s: if the server is reachable the fetch completes in <200ms;
        /// if it isn't, waiting longer only delays stream open on every retry cycle.
        static let fetchMissedMessagesWallClockCap: TimeInterval = 1.0
        /// Faster cap used when the relay is already verified. On a warm relay the
        /// fetchMissedMessages RPC should complete in <100ms; 0.3s gives ample headroom while
        /// keeping the overall broken-relay detection window at ≤1.3s (0.3 + 1.0 stream timeout).
        static let fetchMissedMessagesWallClockCapVerified: TimeInterval = 0.3
        /// After the stream is accepted (server-side ACK), the server should push *something*
        /// (heartbeat ack, queued message, presence update) within this window. If nothing
        /// arrives, the connection is alive at the TLS layer but data isn't flowing — most
        /// often DPI silently dropping UDP after the QUIC handshake. Triggers H2 fallback.
        /// 5s chosen as the trade-off between false positives on slow networks and the 23s+
        /// silent-H3 case observed on RU networks.
        static let firstServerEventWatchdogH3: TimeInterval = 5
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

    // MARK: - Jitter utility

    /// Returns a value in `[base * (1 - fraction), base * (1 + fraction)]`.
    /// Use to spread reconnects across clients and avoid thundering-herd on the server.
    /// - Parameter fraction: 0.2 = ±20%, 0.3 = ±30%, etc.
    static func jitter(_ base: TimeInterval, fraction: Double = 0.2) -> TimeInterval {
        let delta = base * fraction
        return max(0, base + Double.random(in: -delta...delta))
    }

    /// Returns a random delay in `[0, maxSeconds]` for staggering concurrent clients.
    static func randomDelay(max maxSeconds: TimeInterval) -> TimeInterval {
        Double.random(in: 0...maxSeconds)
    }
}
