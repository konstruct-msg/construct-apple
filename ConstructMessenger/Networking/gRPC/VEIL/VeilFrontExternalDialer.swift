//
//  VeilFrontExternalDialer.swift
//  Construct Messenger
//
//  Host-terminated TLS path for veil-front (review §3.1 variant A).
//
//  Why this exists: the Rust client dials the front with rustls carrying a
//  "Chrome131" profile, which is a unique, cheap-to-fingerprint ClientHello — no
//  GREASE, no compress_certificate/status_request/SCT (see construct-veil
//  tls_fingerprint.rs). A phase-0 spike confirmed Network.framework emits the
//  native Apple hello with all of those (cipher 0x4a4a GREASE, ext 27/5/18…), so
//  moving TLS termination here swaps our unique fingerprint for the generic Apple
//  stack (URLSession et al.) — a large anonymity set.
//
//  How it works (persistent-listener form): WE own the stable local gRPC
//  listener. `start()` binds 127.0.0.1:0 once and returns that port for the life
//  of the VEIL session. For every accepted local gRPC connection we dial a FRESH
//  native NWConnection to the relay (native hello, SPKI-pinned), derive the TLS
//  exporter Rust binds AUTH to, and hand Rust that ONE (local socket, decrypted
//  relay duplex) pair via `veil_front_ferry_fd`. Rust runs the veil-front framing
//  (AUTH bound to the exporter, DATA/CHAFF codec) over the plaintext.
//
//  Why not let Rust own the listener: one relay duplex authenticates once and
//  carries exactly one tunnel, so a Rust-side listener could serve only ONE gRPC
//  connection before the port died — every reconnect then forced a fresh port +
//  proxy restart (the startup flap). Keeping the listener here lets the port
//  outlive any single gRPC connection; a reconnect is just the next accept.
//
//  The spike proved the two fiddly halves: SPKI pinning here
//  (SecKeyCopyExternalRepresentation + the P-256 SPKI prefix hashes to the pin)
//  and that one NWConnection send() maps to one TLS record (so record-size
//  control survives via one-frame-per-send on the Rust side).
//
//  Not wired on by default — VeilProxy chooses this path only behind
//  `VeilProxyStore.veilFrontNativeTLS`; the rustls coordinator stays the default
//  and the only path on platforms without Network.framework.
//

import Foundation
import Network
import Security
import CryptoKit

/// Owns the host-terminated veil-front session: one stable local gRPC listener
/// plus one native NWConnection per accepted connection. Retain the instance for
/// the life of the tunnel; `stop()` (or deinit) closes the listener and tears down
/// every active connection, which EOFs each Rust ferry.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`; the inputs are `let`.
/// The instance crosses into `acceptQueue` and per-connection callbacks by design.
final class VeilFrontExternalDialer: @unchecked Sendable {

    enum DialError: Error, CustomStringConvertible {
        case invalidExporter
        case pinMismatch
        case handshakeFailed(String)
        case listenFailed(Int32)
        case socketpairFailed(Int32)
        case ffiFailed(Int32)
        case stopped

        var description: String {
            switch self {
            case .invalidExporter:         return "TLS exporter unavailable or wrong length"
            case .pinMismatch:             return "leaf SPKI did not match the pin"
            case .handshakeFailed(let m):  return "TLS handshake failed: \(m)"
            case .listenFailed(let e):     return "local listener setup failed: errno \(e)"
            case .socketpairFailed(let e): return "socketpair() failed: errno \(e)"
            case .ffiFailed(let rc):       return "veil_front_ferry_fd returned \(rc)"
            case .stopped:                 return "dialer stopped during start"
            }
        }
    }

    /// Upper bound on each TLS handshake to the relay. The happy path reaches
    /// .ready in well under a second; this ceiling ensures a stalled/censored
    /// handshake fails over (at start, to the rustls coordinator; per connection,
    /// by dropping just that connection) instead of hanging.
    private static let handshakeTimeout: TimeInterval = 8

    /// A handshaken, pin-verified native connection plus the exporter Rust binds
    /// AUTH to for it.
    private struct Prepared {
        let conn: NWConnection
        let exporter: Data
    }

    // Manager state.
    private let acceptQueue = DispatchQueue(label: "veil.front.external.accept", qos: .userInitiated)
    private let lock = NSLock()               // guards listenFD / sessions / stopped
    private var listenFD: Int32 = -1
    private var stopped = false
    private var sessions: [ObjectIdentifier: Session] = [:]  // active per-connection ferries

    // Inputs.
    private let host: String
    private let port: UInt16
    private let sni: String
    private let pinnedSpkiHex: String
    private let capabilityV2B64: String
    private let veilSkHex: String
    private let ticketB64: String

    /// - Parameters mirror `VeilRelay`: `host:port` split out, `sni` = tlsServerName,
    ///   `pinnedSpkiHex` = pinnedSpki, and the AUTH material (v3 capability+sk, or v2 ticket).
    init(host: String, port: UInt16, sni: String, pinnedSpkiHex: String,
         capabilityV2B64: String, veilSkHex: String, ticketB64: String) {
        self.host = host
        self.port = port
        self.sni = sni
        self.pinnedSpkiHex = pinnedSpkiHex
        self.capabilityV2B64 = capabilityV2B64
        self.veilSkHex = veilSkHex
        self.ticketB64 = ticketB64
    }

    deinit { stop() }

    /// Validates the native path, binds the stable local gRPC listener, and returns
    /// its port. Throws `DialError` on any failure (everything left torn down), so
    /// the caller can fall back to the rustls coordinator.
    func start() async throws -> UInt16 {
        // 1. Validate one native dial up front: reachability + SPKI pin + exporter.
        //    On failure the caller falls back to rustls before committing veil-active.
        let prepared = try await dialAndValidate()

        // 2. Bind the stable local gRPC listener. This port outlives any single
        //    gRPC connection — each accept below dials its own fresh NWConnection.
        let bound: (fd: Int32, port: UInt16)
        do {
            bound = try Self.bindLoopbackListener()
        } catch {
            prepared.conn.cancel()
            throw error
        }

        guard adoptListener(bound.fd) else {
            prepared.conn.cancel()
            close(bound.fd)
            throw DialError.stopped
        }

        // 3. Serve the validated connection as the first accepted, then loop.
        acceptQueue.async { [weak self] in self?.runAcceptLoop(first: prepared) }
        return bound.port
    }

    /// Publishes the bound listener fd unless `stop()` already ran. Kept synchronous
    /// because `start()` is async and an NSLock must not be held across a suspension.
    private func adoptListener(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return false }
        listenFD = fd
        return true
    }

    /// Closes the listener (which unblocks the accept loop) and tears down every
    /// active connection. Idempotent and synchronous.
    func stop() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let fd = listenFD
        listenFD = -1
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()

        if fd >= 0 { close(fd) }   // unblocks the blocking accept()
        for s in active { s.teardown() }
    }

    // MARK: - Accept loop

    private func runAcceptLoop(first: Prepared?) {
        var first = first
        while true {
            let fd = currentListenFD()
            if fd < 0 { break }
            let localFD = accept(fd, nil, nil)
            if localFD < 0 { break }   // listener closed (stop()) or fatal error
            let prepared = first
            first = nil
            serve(localFD: localFD, prepared: prepared)
        }
        // A validated-but-never-served connection (stop() before any accept) is dropped.
        first?.conn.cancel()
    }

    private func currentListenFD() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return listenFD
    }

    /// Wire one accepted local gRPC socket to a native NWConnection (the validated
    /// one for the first connection, a fresh dial otherwise) and hand the pair to Rust.
    private func serve(localFD: Int32, prepared: Prepared?) {
        Task { [weak self] in
            guard let self else { close(localFD); return }

            // A fresh connection per accept — except the very first, which reuses
            // the connection start() already validated (saves one handshake).
            let ready: Prepared
            if let prepared {
                ready = prepared
            } else {
                do {
                    ready = try await self.dialAndValidate()
                } catch {
                    Log.info("VEIL native-TLS: per-connection dial failed, dropping gRPC conn: \(error)",
                             category: "VEIL")
                    close(localFD)
                    return
                }
            }

            self.startSession(localFD: localFD, ready: ready)
        }
    }

    /// Create the socketpair, hand Rust the (localFD, relay duplex, exporter) triple,
    /// and start pumping our socketpair end ↔ the NWConnection.
    private func startSession(localFD: Int32, ready: Prepared) {
        // socketpair: Rust gets one end (decrypted relay duplex), we pump the other.
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            ready.conn.cancel()
            close(localFD)
            Log.info("VEIL native-TLS: socketpair failed errno \(errno)", category: "VEIL")
            return
        }
        let rustFD = fds[1]
        let swiftFD = fds[0]
        _ = fcntl(swiftFD, F_SETFL, fcntl(swiftFD, F_GETFL, 0) | O_NONBLOCK)

        // Rust adopts localFD and rustFD unconditionally (it closes both), so we
        // must not touch them after the call. We keep swiftFD for the pump.
        let ffiRC: Int32 = ready.exporter.withUnsafeBytes { expBuf -> Int32 in
            let expPtr = expBuf.bindMemory(to: UInt8.self).baseAddress
            return capabilityV2B64.withCString { capPtr in
                veilSkHex.withCString { skPtr in
                    ticketB64.withCString { ticketPtr in
                        veil_front_ferry_fd(localFD, rustFD, expPtr, 32, capPtr, skPtr, ticketPtr)
                    }
                }
            }
        }
        guard ffiRC == 0 else {
            // localFD + rustFD already owned/closed by Rust; tear down our side.
            close(swiftFD)
            ready.conn.cancel()
            Log.info("VEIL native-TLS: \(DialError.ffiFailed(ffiRC))", category: "VEIL")
            return
        }

        // Track the session so stop() can tear it down; the session removes itself
        // when its pump sees EOF (the ferry ended).
        let session = Session(conn: ready.conn, swiftFD: swiftFD) { [weak self] s in
            self?.removeSession(s)
        }
        var shouldStart = true
        lock.lock()
        if stopped {
            shouldStart = false
        } else {
            sessions[ObjectIdentifier(session)] = session
        }
        lock.unlock()

        if shouldStart {
            session.startPump()
        } else {
            session.teardown()   // raced stop() — clean up immediately
        }
    }

    private func removeSession(_ session: Session) {
        lock.lock()
        sessions.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
    }

    // MARK: - TLS dial (fresh native NWConnection, handshaken, pin-verified)

    /// Opens one native NWConnection, waits for the pinned TLS 1.3 handshake, and
    /// derives the exporter. Bounded by `handshakeTimeout`. Returns a `Prepared`
    /// ready to ferry, or throws.
    private func dialAndValidate() async throws -> Prepared {
        // Per-connection serial queue for the verify block, handshake handler, and
        // NWConnection callbacks. It must NOT be `acceptQueue`, which is parked in a
        // blocking accept() — a verify block dispatched there would never run and the
        // handshake would stall to the timeout.
        let connQueue = DispatchQueue(label: "veil.front.external.conn", qos: .userInitiated)
        let conn = makeConnection(callbackQueue: connQueue)

        do {
            let exporter = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                // NWConnection's handshake wait is otherwise unbounded: a stalled or
                // censored handshake would never emit .ready or .failed. Arm a one-shot
                // timeout on the same serial queue as the state handler so the two can't
                // race a double-resume — whichever fires first clears the handler and
                // cancels the timer.
                let timeout = DispatchWorkItem {
                    conn.stateUpdateHandler = nil
                    conn.cancel()
                    cont.resume(throwing: DialError.handshakeFailed("timeout after \(Self.handshakeTimeout)s"))
                }
                connQueue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: timeout)
                conn.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        timeout.cancel()
                        conn.stateUpdateHandler = nil
                        guard let self, let data = self.deriveExporter(conn) else {
                            cont.resume(throwing: DialError.invalidExporter); return
                        }
                        cont.resume(returning: data)
                    case .failed(let error):
                        timeout.cancel()
                        conn.stateUpdateHandler = nil
                        cont.resume(throwing: DialError.handshakeFailed("\(error)"))
                    case .cancelled:
                        timeout.cancel()
                        conn.stateUpdateHandler = nil
                        cont.resume(throwing: DialError.handshakeFailed("cancelled"))
                    default:
                        break
                    }
                }
                conn.start(queue: connQueue)
            }
            guard exporter.count == 32 else { conn.cancel(); throw DialError.invalidExporter }
            return Prepared(conn: conn, exporter: exporter)
        } catch {
            conn.cancel()
            throw error
        }
    }

    private func makeConnection(callbackQueue: DispatchQueue) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "h2")
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { [pinnedSpkiHex] _, trust, complete in
                complete(Self.spkiMatchesPin(trust, pinHex: pinnedSpkiHex))
            },
            callbackQueue
        )
        return NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: tls)
        )
    }

    /// The exact exporter Rust binds AUTH to: `EXPORTER_LABEL`, empty context, 32 bytes.
    private func deriveExporter(_ conn: NWConnection) -> Data? {
        guard let md = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        let sec = md.securityProtocolMetadata
        let label = "construct veil-front auth v1"   // must equal construct_veil_protocol::EXPORTER_LABEL
        return label.withCString { c -> Data? in
            guard let secret = sec_protocol_metadata_create_secret(sec, strlen(c), c, 32) else { return nil }
            // sec_protocol_metadata_create_secret returns dispatch_data_t; erase to
            // Any so the compiler allows the runtime bridge to Data (verified by the
            // phase-0 spike, which read the exporter bytes back this way).
            guard let data = (secret as Any) as? Data else { return nil }
            let h6 = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
            Log.info("VEIL native-TLS: exporter derived, len=\(data.count) sha6=\(h6)", category: "VEIL")
            return data
        }
    }

    /// EC P-256 pinning: rebuild the leaf SubjectPublicKeyInfo DER from the raw
    /// public key and compare its SHA-256 to the pin. The RU front is Let's Encrypt
    /// ECDSA P-256; if a front ever ships a non-EC key this must grow a branch.
    private static let ecP256SpkiPrefix: [UInt8] = [
        0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,
        0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00
    ]

    private static func spkiMatchesPin(_ trust: sec_trust_t, pinHex: String) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return false
        }
        let spki = Data(ecP256SpkiPrefix) + raw
        let got = SHA256.hash(data: spki).map { String(format: "%02x", $0) }.joined()
        return got == pinHex
    }

    // MARK: - Local listener

    /// Bind a blocking loopback TCP listener on an ephemeral port. Returns the fd
    /// and the port. The accept loop runs on `acceptQueue`; `stop()` closes the fd
    /// to unblock it.
    private static func bindLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DialError.listenFailed(errno) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // network byte order

        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else { let e = errno; close(fd); throw DialError.listenFailed(e) }
        guard listen(fd, 16) == 0 else { let e = errno; close(fd); throw DialError.listenFailed(e) }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRC = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameRC == 0 else { let e = errno; close(fd); throw DialError.listenFailed(e) }
        let port = UInt16(bigEndian: boundAddr.sin_port)
        guard port > 0 else { close(fd); throw DialError.listenFailed(0) }
        return (fd, port)
    }
}

// MARK: - Per-connection ferry session

/// One accepted gRPC connection bridged to one native NWConnection. Owns the
/// NWConnection and our socketpair end; pumps bytes both ways. When either side
/// EOFs it tears down and calls `onClosed` so the dialer forgets it.
private final class Session {
    private let queue = DispatchQueue(label: "veil.front.external.session", qos: .userInitiated)
    private let lock = NSLock()
    private let conn: NWConnection
    private var channel: DispatchIO?
    private var swiftFD: Int32
    private var closed = false
    private let onClosed: (Session) -> Void

    init(conn: NWConnection, swiftFD: Int32, onClosed: @escaping (Session) -> Void) {
        self.conn = conn
        self.swiftFD = swiftFD
        self.onClosed = onClosed
    }

    /// Begin pumping: Rust→relay (socketpair→NWConnection) and relay→Rust
    /// (NWConnection→socketpair). Called once.
    func startPump() {
        let ch = DispatchIO(type: .stream, fileDescriptor: swiftFD, queue: queue) { [weak self] _ in
            // Cleanup handler: the channel is done with the fd — close it here (the
            // one place swiftFD is closed once a channel exists) and end the session.
            guard let self else { return }
            self.lock.lock()
            if self.swiftFD >= 0 { close(self.swiftFD); self.swiftFD = -1 }
            self.lock.unlock()
            self.finish()
        }
        ch.setLimit(lowWater: 1)   // deliver bytes as soon as any arrive

        lock.lock()
        if closed {
            lock.unlock()
            ch.close(flags: .stop)
            return
        }
        channel = ch
        lock.unlock()

        // Rust → relay: bytes Rust writes to its socketpair end arrive here; send them.
        ch.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, _ in
            if let self, let data, !data.isEmpty {
                self.conn.send(content: Data(data), completion: .contentProcessed { _ in })
            }
            if done { self?.finish() }   // EOF from Rust side → end session
        }

        // relay → Rust: decrypted bytes from NWConnection get written to our end.
        pumpDown()
    }

    private func pumpDown() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                let ch = self.channel
                self.lock.unlock()
                if let ch {
                    let dd = data.withUnsafeBytes { DispatchData(bytes: $0) }
                    ch.write(offset: 0, data: dd, queue: self.queue) { _, _, _ in }
                }
            }
            if isComplete || error != nil {
                self.finish()    // relay closed → end session
                return
            }
            self.pumpDown()
        }
    }

    /// Tear down and notify the dialer. Safe to call multiple times / from either pump.
    private func finish() {
        teardown()
        onClosed(self)
    }

    /// Cancel the NWConnection and close the socketpair end. Idempotent.
    func teardown() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let ch = channel
        channel = nil
        let fd = swiftFD
        lock.unlock()

        conn.cancel()
        if let ch {
            ch.close(flags: .stop)   // its cleanup handler closes swiftFD
        } else if fd >= 0 {
            close(fd)
            lock.lock(); swiftFD = -1; lock.unlock()
        }
    }
}
