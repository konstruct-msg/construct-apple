//
//  VeilProxy.swift
//  Construct Messenger
//
//  Serial actor managing the lifecycle of the local Rust VEIL proxy.
//
//  Selection of the underlying obfuscator (obfs4 vs WebTunnel vs future methods)
//  happens inside the Rust coordinator via parallel happy-eyeballs probing. This
//  actor is now a thin lifecycle wrapper around a single `veil_start` FFI call.
//

import Foundation

// MARK: - Result

/// Outcome of `VeilProxy.ensure(relay:)`.
///
/// `restarted == true` means a new Rust proxy instance was started. The previously
/// listening OS socket has been closed; even if the new instance happened to bind
/// the same ephemeral port, any TCP connection an upstream caller may already hold
/// to `127.0.0.1:port` is dead and must be re-established.
struct VeilProxyEnsureResult: Sendable {
    let port: UInt16
    let restarted: Bool
    /// Which obfuscator won the probe race inside Rust. nil when reusing a prior session.
    let method: VeilMethod?
    /// Probe latency reported by Rust, in milliseconds. nil when reusing a prior session.
    let latencyMs: UInt32?
}

// MARK: - Error

enum VeilProxyError: Error, Sendable {
    /// Rust FFI returned a non-zero code.
    case startFailed(underlying: VeilProxyRuntimeError)

    var localizedDescription: String {
        switch self {
        case .startFailed(let e): return e.userFacingMessage
        }
    }
}

// MARK: - Actor

/// Manages start / stop / restart of the Rust VEIL proxy.
///
/// Usage:
/// ```swift
/// let port = try await proxy.start(relay: relay)   // start for relay
/// let port = try await proxy.ensure(relay: relay)  // reuse if same relay
/// await proxy.stop()
/// ```
actor VeilProxy {

    // MARK: - State

    /// Local port the Rust proxy is listening on, or nil when stopped.
    private(set) var port: UInt16?

    /// Relay the proxy is currently running for.
    private(set) var currentRelay: VeilRelay?

    /// Which obfuscator the coordinator picked for the active session.
    private(set) var activeMethod: VeilMethod?

    /// Host-terminated TLS veil-front session (review §3.1 variant A); nil unless
    /// that path is active. Retained so its NWConnection + socketpair pump outlive
    /// `start(relay:)`.
    private var externalDialer: VeilFrontExternalDialer?

    private let runtime: VeilProxyRuntime

    // MARK: - Init

    init(runtime: VeilProxyRuntime = NativeVeilRuntime()) {
        self.runtime = runtime
    }

    // MARK: - Public API

    /// Returns the current port if `relay` is already running.
    /// Restarts the proxy for `relay` otherwise.
    ///
    /// The `restarted` flag is `true` whenever a fresh Rust proxy instance was started;
    /// callers must treat any existing TCP connection to `127.0.0.1:port` as dead in
    /// that case, even if the new instance was assigned the same ephemeral port.
    @discardableResult
    func ensure(relay: VeilRelay) async throws -> VeilProxyEnsureResult {
        if let p = port, currentRelay?.address == relay.address {
            return VeilProxyEnsureResult(port: p, restarted: false, method: activeMethod, latencyMs: nil)
        }
        let outcome = try await start(relay: relay)
        return VeilProxyEnsureResult(port: outcome.port, restarted: true, method: outcome.method, latencyMs: outcome.latencyMs)
    }

    /// Starts the proxy for `relay`, stopping any currently running proxy first.
    ///
    /// The Rust coordinator probes obfs4 + WebTunnel in parallel and binds the winner.
    @discardableResult
    func start(relay: VeilRelay) async throws -> VeilStartOutcome {
        stopIfRunning()

        // Host-terminated TLS veil-front (opt-in): terminate TLS in Network.framework
        // for the native Apple ClientHello fingerprint. Falls through to the rustls
        // coordinator when the flag is off, the relay carries no veil-front material,
        // or the dial fails — connectivity is never sacrificed to this path.
        if VeilProxyStore.veilFrontEnabled, VeilProxyStore.veilFrontNativeTLS,
           let outcome = await startNativeVeilFront(relay: relay) {
            return outcome
        }

        let fingerprint = await MainActor.run { NetworkFingerprint.current() }
        let scoresPath  = NetworkFingerprint.scoresDatabasePath

        switch runtime.startUnified(relay: relay, fingerprint: fingerprint, scoresPath: scoresPath) {
        case .success(let outcome):
            commit(port: outcome.port, relay: relay, method: outcome.method)
            Log.info(
                "VEIL: relay=\(relay.address) method=\(outcome.method.label) port=\(outcome.port) latency=\(outcome.latencyMs)ms",
                category: "VEIL"
            )
            return outcome
        case .failure(let err):
            throw VeilProxyError.startFailed(underlying: err)
        }
    }

    /// Stops the proxy unconditionally. No-op if already stopped.
    func stop() {
        stopIfRunning()
    }

    /// True if the Rust process is alive (re-checks native flag — Swift state can lag
    /// after the OS suspends background threads).
    var isAlive: Bool {
        runtime.isAlive()
    }

    // MARK: - Private

    private func commit(port p: UInt16, relay: VeilRelay, method: VeilMethod) {
        port = p
        currentRelay = relay
        activeMethod = method
    }

    /// Host-terminated TLS path. Returns nil to fall back to the rustls coordinator
    /// (no relay material, or the dial failed); never throws — an experimental
    /// fingerprint path must not cost connectivity.
    private func startNativeVeilFront(relay: VeilRelay) async -> VeilStartOutcome? {
        guard let spki = relay.pinnedSpki, !spki.isEmpty,
              let (host, port) = Self.splitHostPort(relay.address) else { return nil }
        let capabilityV2 = relay.veilCapabilityV2 ?? ""
        let veilSk       = relay.veilSkHex ?? ""
        let ticket       = relay.veilFrontTicket ?? ""
        guard !(capabilityV2.isEmpty && ticket.isEmpty) else { return nil }  // no AUTH material

        let dialer = VeilFrontExternalDialer(
            host: host, port: port, sni: relay.tlsServerName ?? host,
            pinnedSpkiHex: spki, capabilityV2B64: capabilityV2,
            veilSkHex: veilSk, ticketB64: ticket
        )
        do {
            // The dial is internally bounded (VeilFrontExternalDialer.start caps the
            // otherwise-unbounded NWConnection handshake), so a stalled/censored
            // handshake surfaces here as a throw and falls back to rustls rather than
            // wedging the whole VEIL start in veil-probing — connectivity first.
            let localPort = try await dialer.start()
            externalDialer = dialer
            commit(port: localPort, relay: relay, method: .veilFront)
            Log.info(
                "VEIL: relay=\(relay.address) method=veil-front(native-TLS) port=\(localPort)",
                category: "VEIL"
            )
            return VeilStartOutcome(port: localPort, method: .veilFront, latencyMs: 0)
        } catch {
            Log.error("VEIL native-TLS dial failed/timeout, falling back to rustls: \(error)", category: "VEIL")
            dialer.stop()
            return nil
        }
    }

    /// Splits `"host:port"` (host may be an IPv4/hostname; last colon wins).
    private static func splitHostPort(_ addr: String) -> (String, UInt16)? {
        guard let idx = addr.lastIndex(of: ":"),
              let port = UInt16(addr[addr.index(after: idx)...]) else { return nil }
        return (String(addr[..<idx]), port)
    }

    private func stopIfRunning() {
        guard port != nil else { return }
        externalDialer?.stop()
        externalDialer = nil
        runtime.stop()
        port = nil
        currentRelay = nil
        activeMethod = nil
    }
}
