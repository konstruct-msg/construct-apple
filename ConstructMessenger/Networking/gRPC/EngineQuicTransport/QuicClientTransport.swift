#if os(iOS)
import Foundation
import GRPCCore

/// gRPC-swift v2 `ClientTransport` backed by the `construct-transport` Rust QUIC/HTTP-3
/// stack (`QuicChannel` / `QuicStream` over UniFFI).
///
/// Experimental — gated by `FeatureFlags.engineQuicExperimental` and never part of the
/// happy-eyeballs race; the `TransportRouter` falls back to the H2 path on any failure.
/// This carries opaque gRPC message bytes only — crypto stays on the direct UniFFI path
/// (see `decisions/quic-h3-transport-dedicated-rust-stack.md`).
///
/// One `QuicChannel` (a single multiplexed QUIC/H3 connection) is established in
/// `connect()`; every `withStream` opens a fresh request stream over it. The Rust FFI
/// owns gRPC framing (`grpc::encode_frame` / `take_frame`), so this adapter passes raw,
/// unframed message bodies in both directions.
final class QuicClientTransport: ClientTransport, @unchecked Sendable {
    typealias Bytes = GRPCNetworkTransportBytes

    struct Config: Sendable {
        var host: String
        var port: UInt16
        /// TLS SNI; must match the gateway certificate SAN.
        var serverName: String
        /// Pinned gateway certificate (DER) — the gateway is self-signed.
        var trustCert: Data
        /// When set, Salamander-obfuscate every datagram with this PSK (the gateway must use the
        /// same PSK). nil = plain QUIC. Shared per-gateway secret, never per-user — see
        /// decisions/salamander-psk-shared-per-gateway.md.
        var obfPsk: Data?
    }

    private let config: Config
    private let state = StateMachine()

    var retryThrottle: RetryThrottle? { nil }

    init(config: Config) {
        self.config = config
    }

    func connect() async throws {
        let obfLabel = config.obfPsk == nil ? "plain" : "salamander"
        Log.info("engine-QUIC transport build=\(transportBuildMarker()) [\(obfLabel)] → \(config.host):\(config.port)", category: "QuicTransport")
        state.markConnecting()
        // Timed because three device runs were spent inferring this interval from the gap between
        // two log lines, and the inference was wrong each time. The "engine-QUIC persistent
        // connection closed" ERROR is written when the *channel* tears down, which is not when the
        // handshake gave up: on 2026-08-24 those were 07:35:25 and 07:35:35, and the 3s handshake
        // budget could not account for the difference. One number here ends the arithmetic.
        let startedAt = Date()
        do {
            let channel: QuicChannel
            if let psk = config.obfPsk {
                channel = try await QuicChannel.connectObfuscated(
                    host: config.host,
                    port: config.port,
                    serverName: config.serverName,
                    trustCert: config.trustCert,
                    psk: psk
                )
            } else {
                channel = try await QuicChannel.connect(
                    host: config.host,
                    port: config.port,
                    serverName: config.serverName,
                    trustCert: config.trustCert
                )
            }
            Log.info(
                "engine-QUIC connected in \(Self.elapsedMs(since: startedAt))ms → \(config.host):\(config.port)",
                category: "QuicTransport"
            )
            state.setRunning(channel)
        } catch {
            // The elapsed time is the whole point of this line: it separates "nothing answered on
            // UDP/443" (≈3000ms, the Rust HANDSHAKE_TIMEOUT) from name resolution (its own 2000ms
            // budget, its own message) from anything slower, which is neither and needs looking at.
            Log.error(
                "engine-QUIC connect failed after \(Self.elapsedMs(since: startedAt))ms "
                + "→ \(config.host):\(config.port): \(error)",
                category: "QuicTransport"
            )
            let rpcError = RPCError(code: .unavailable, message: "QUIC connect failed: \(error)")
            state.fail(rpcError)
            throw rpcError
        }
        // Hold the connection open until graceful shutdown, mirroring the H2/H3 transports.
        await state.waitForShutdown()
    }

    private static func elapsedMs(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    func beginGracefulShutdown() {
        state.shutdown()
    }

    func config(forMethod descriptor: MethodDescriptor) -> MethodConfig? { nil }

    func withStream<T: Sendable>(
        descriptor: MethodDescriptor,
        options: CallOptions,
        _ closure: (_ stream: RPCStream<Inbound, Outbound>, _ context: ClientContext) async throws -> T
    ) async throws -> T {
        // Await the established channel — the QUIC handshake completes asynchronously in
        // connect(), so reading it eagerly would race the first RPC ahead of the handshake.
        let channel = try await state.waitForChannel()
        let path = "/\(descriptor.fullyQualifiedMethod)"
        let rpcStream = makeRPCStream(descriptor: descriptor, channel: channel, path: path)
        let context = ClientContext(
            descriptor: descriptor,
            remotePeer: "quic:\(config.host):\(config.port)",
            localPeer: "quic:local"
        )
        return try await closure(rpcStream, context)
    }

    private func makeRPCStream(
        descriptor: MethodDescriptor,
        channel: QuicChannel,
        path: String
    ) -> RPCStream<Inbound, Outbound> {
        let (inbound, continuation) = AsyncThrowingStream<RPCResponsePart<Bytes>, any Error>.makeStream()
        let writer = QuicOutbound(channel: channel, path: path, continuation: continuation)
        return RPCStream(
            descriptor: descriptor,
            inbound: RPCAsyncSequence(wrapping: inbound),
            outbound: RPCWriter<RPCRequestPart<Bytes>>.Closable(wrapping: writer)
        )
    }
}

// MARK: - Outbound writer

/// Translates the gRPC request part stream (`metadata` → `message`* → end) into
/// `QuicStream` calls, and spawns the receive pump that feeds the inbound continuation.
private final class QuicOutbound: ClosableRPCWriterProtocol, @unchecked Sendable {
    typealias Element = RPCRequestPart<GRPCNetworkTransportBytes>

    private let channel: QuicChannel
    private let path: String
    private let continuation: AsyncThrowingStream<RPCResponsePart<GRPCNetworkTransportBytes>, any Error>.Continuation

    /// Set once the request HEADERS (gRPC `.metadata`) are written and the stream opens.
    /// gRPC-swift serialises calls into a single outbound writer, so no locking is needed.
    private var stream: QuicStream?

    init(
        channel: QuicChannel,
        path: String,
        continuation: AsyncThrowingStream<RPCResponsePart<GRPCNetworkTransportBytes>, any Error>.Continuation
    ) {
        self.channel = channel
        self.path = path
        self.continuation = continuation
    }

    func write(contentsOf elements: some Sequence<Element>) async throws {
        for element in elements {
            try await write(element)
        }
    }

    func write(_ element: Element) async throws {
        switch element {
        case .metadata(let metadata):
            // Request HEADERS → open the H3 request stream carrying gRPC metadata
            // (authorization, x-user-id, …). Binary `-bin` values are base64 via encoded().
            let headers = metadata.map { GrpcHeader(key: $0.key, value: $0.value.encoded()) }
            let stream = try await channel.openStream(path: path, metadata: headers)
            self.stream = stream
            startReceivePump(on: stream)

        case .message(let bytes):
            guard let stream else {
                throw RPCError(code: .internalError, message: "QUIC stream message before metadata.")
            }
            do {
                try await stream.sendMessage(message: bytes.data)
                #if DEBUG
                Log.debug("QUIC send ok (\(bytes.data.count)B) \(path)", category: "QuicTransport")
                #endif
            } catch {
                Log.error("QUIC send FAILED \(path): \(error)", category: "QuicTransport")
                throw error
            }
        }
    }

    func finish() async {
        try? await stream?.finish()
    }

    func finish(throwing error: any Error) async {
        // No explicit reset in the FFI yet; closing the send side + failing inbound is enough.
        try? await stream?.finish()
        continuation.finish(throwing: error)
    }

    /// Drains the response: HTTP status → initial metadata → messages → gRPC trailers.
    private func startReceivePump(on stream: QuicStream) {
        let continuation = self.continuation
        let path = self.path
        // Poll live quinn connection stats so on-device keep-alive is observable on internal
        // (DEBUG / TestFlight) builds — `ping_tx` MUST grow (keep-alive firing) and `rx_pkts` MUST
        // grow (acks arriving); if either stalls while the stream is parked on recv, the connection
        // idle-dies at ~30s (the driver-starvation class in construct-transport `ffi.rs`). Gated to
        // internal so the external release carries no per-10s stats log (silent-transport-ui).
        #if DEBUG || INTERNAL_TOOLS
        let channel = self.channel
        let statsTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                if let stats = try? await channel.connectionStats() {
                    Log.info("QUIC stats \(stats) \(path)", category: "QuicTransport")
                }
            }
        }
        #endif
        Task {
            #if DEBUG || INTERNAL_TOOLS
            defer { statsTask.cancel() }
            #endif
            do {
                let httpStatus = try await stream.recvResponse()
                guard httpStatus == 200 else {
                    continuation.yield(.status(
                        Status(code: .unavailable, message: "QUIC gateway HTTP \(httpStatus)"),
                        [:]
                    ))
                    continuation.finish()
                    return
                }
                // Response headers are not surfaced by the FFI yet; gRPC initial metadata is empty.
                continuation.yield(.metadata([:]))

                #if DEBUG
                var received = 0
                #endif
                while let message = try await stream.recvMessage() {
                    #if DEBUG
                    received += 1
                    Log.debug("QUIC recv msg #\(received) (\(message.count)B) \(path)", category: "QuicTransport")
                    #endif
                    continuation.yield(.message(GRPCNetworkTransportBytes(message)))
                }

                let trailers = try await stream.recvTrailers()
                let (status, trailingMetadata) = Self.parseStatus(from: trailers)
                continuation.yield(.status(status, trailingMetadata))
                continuation.finish()
            } catch {
                Log.error("QUIC recv pump error \(path): \(error)", category: "QuicTransport")
                continuation.finish(throwing: error)
            }
        }
    }

    /// Maps gRPC trailers to a `Status` + trailing `Metadata`, reading `grpc-status`
    /// (numeric code) and `grpc-message` (percent-encoded text) per the gRPC wire spec.
    private static func parseStatus(from trailers: [GrpcHeader]) -> (Status, Metadata) {
        var code = Status.Code.ok
        var message = ""
        var metadata = Metadata()
        for header in trailers {
            switch header.key.lowercased() {
            case "grpc-status":
                if let raw = Int(header.value), let mapped = Status.Code(rawValue: raw) {
                    code = mapped
                }
            case "grpc-message":
                message = header.value.removingPercentEncoding ?? header.value
            default:
                metadata.addString(header.value, forKey: header.key)
            }
        }
        return (Status(code: code, message: message), metadata)
    }
}

// MARK: - Connection state

/// Lifecycle gate. `connect()` establishes the channel asynchronously (the QUIC handshake
/// takes ~100ms); `withStream` must therefore *await* readiness rather than read the channel
/// eagerly — otherwise the first RPC races ahead of the handshake and fails with
/// "transport is not connected" (observed device bug). Holds the channel, fails pending
/// stream waiters on connect-failure/shutdown, and provides the shutdown latch for connect().
private final class StateMachine: @unchecked Sendable {
    private enum Phase { case idle, connecting, running, failed, done }

    private let lock = NSLock()
    private var phase: Phase = .idle
    private var _channel: QuicChannel?
    private var failureError: (any Error)?
    private var channelWaiters: [CheckedContinuation<QuicChannel, any Error>] = []
    private var shutdownContinuation: CheckedContinuation<Void, Never>?

    func markConnecting() {
        lock.withLock { if phase == .idle { phase = .connecting } }
    }

    func setRunning(_ channel: QuicChannel) {
        let waiters: [CheckedContinuation<QuicChannel, any Error>] = lock.withLock {
            _channel = channel
            phase = .running
            let w = channelWaiters
            channelWaiters = []
            return w
        }
        for w in waiters { w.resume(returning: channel) }
    }

    /// Connect failed: fail any pending stream waiters and release the shutdown latch.
    func fail(_ error: any Error) {
        let (waiters, shutdown, retired): ([CheckedContinuation<QuicChannel, any Error>], CheckedContinuation<Void, Never>?, QuicChannel?) = lock.withLock {
            if phase != .done { phase = .failed; failureError = error }
            let ch = _channel
            _channel = nil
            let w = channelWaiters; channelWaiters = []
            let s = shutdownContinuation; shutdownContinuation = nil
            return (w, s, ch)
        }
        retire(retired, why: "connect failed")
        for w in waiters { w.resume(throwing: error) }
        shutdown?.resume()
    }

    func shutdown() {
        let (waiters, cont, retired): ([CheckedContinuation<QuicChannel, any Error>], CheckedContinuation<Void, Never>?, QuicChannel?) = lock.withLock {
            phase = .done
            let ch = _channel
            _channel = nil
            let w = channelWaiters; channelWaiters = []
            let c = shutdownContinuation; shutdownContinuation = nil
            return (w, c, ch)
        }
        retire(retired, why: "graceful shutdown")
        let err = RPCError(code: .unavailable, message: "QUIC transport shut down.")
        for w in waiters { w.resume(throwing: err) }
        cont?.resume()
    }

    /// Close the Rust connection, rather than dropping our reference to it and hoping.
    ///
    /// THE HEAT. Releasing `_channel` retires the transport on the Swift side only; the quinn
    /// endpoint behind it lives until the last `Arc` in Rust goes, and the stats task in
    /// `startReceivePump` holds one for as long as it is polling. So an abandoned QUIC connection
    /// kept its endpoint driver running, and on a network that answers UDP with ICMP unreachables
    /// that driver burns a core — `spin_free_socket` absorbs the errors without spinning *per
    /// error*, but nothing was asking why the socket was still being polled at all. Build 630,
    /// 2026-08-22, nine minutes after the client had given up on QUIC entirely:
    ///
    ///     11:34:41  Fast-UDP (QUIC/H3) failed to open [accept_timeout] — H2 for the rest of this session
    ///     11:34:41  engine-QUIC persistent connection force-invalidated (gen=4)
    ///     11:34:48  QUIC stats tx_pkts=17 rx_pkts=2 ping_tx=1 close=None     ← still pinging
    ///     11:36:19  thermal=fair     cpu=115.0%  transport=conns=1 udperr=277065498
    ///     11:37:54  thermal=serious  cpu=106.3%  transport=conns=1 udperr=529574692
    ///     11:43:30  thermal=serious  cpu=116.3%  transport=conns=1 udperr=1255362137
    ///
    /// `udperr` grew by 2.3 million per second for as long as the app was foregrounded, on a
    /// connection nothing intended to use again. `conns=1` is the same fact, and it never fell.
    ///
    /// `QuicChannel.close()` was added on 2026-08-09 to make retirement explicit instead of a
    /// consequence of drop order — and shipped with no caller, which is the producer-without-a-
    /// consumer defect in its other direction. This is the caller.
    private func retire(_ channel: QuicChannel?, why: String) {
        guard let channel else { return }
        channel.close()
        Log.info("engine-QUIC connection closed (\(why))", category: "QuicTransport")
    }

    /// Await the established channel: returns immediately when running, throws if the
    /// transport already failed/shut down, otherwise suspends until `connect()` resolves.
    func waitForChannel() async throws -> QuicChannel {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<QuicChannel, any Error>) in
            let resume: (() -> Void)? = lock.withLock {
                switch phase {
                case .running:
                    if let ch = _channel { return { cont.resume(returning: ch) } }
                    channelWaiters.append(cont); return nil
                case .failed:
                    let e = failureError ?? RPCError(code: .unavailable, message: "QUIC connect failed.")
                    return { cont.resume(throwing: e) }
                case .done:
                    return { cont.resume(throwing: RPCError(code: .unavailable, message: "QUIC transport shut down.")) }
                case .idle, .connecting:
                    channelWaiters.append(cont); return nil
                }
            }
            resume?()
        }
    }

    func waitForShutdown() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let alreadyDone: Bool = lock.withLock {
                if phase == .done || phase == .failed { return true }
                shutdownContinuation = cont
                return false
            }
            if alreadyDone { cont.resume() }
        }
    }
}
#endif
