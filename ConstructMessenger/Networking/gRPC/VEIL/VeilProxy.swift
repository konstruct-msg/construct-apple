//
//  VeilProxy.swift
//  Construct Messenger
//
//  Serial actor managing the lifecycle of the local Rust ICE proxy process.
//
//  Replaces the proxy start/stop/restart state machine scattered across
//  VeilProxyManager. The actor executor serialises all calls — no generation
//  counters, crash-restart flags, or resetAllProxyState() needed.
//
//  Transport selection priority (same as before):
//    1. WebTunnel (ICE v2) when relay has wtPath + tlsServerName
//    2. obfs4 inside TLS with SPKI pinning when tlsServerName + pinnedSpki present
//    3. obfs4 inside TLS (CA chain) when tlsServerName present
//    4. Plain obfs4 (no TLS wrapper)
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

/// Manages start / stop / restart of the Rust ICE proxy.
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

    /// Whether the active transport is WebTunnel (true) or obfs4 (false).
    private(set) var isWebTunnel: Bool = false

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
    func ensure(relay: VeilRelay) throws -> VeilProxyEnsureResult {
        if let p = port, currentRelay?.address == relay.address {
            return VeilProxyEnsureResult(port: p, restarted: false)
        }
        let p = try start(relay: relay)
        return VeilProxyEnsureResult(port: p, restarted: true)
    }

    /// Starts the proxy for `relay`, stopping any currently running proxy first.
    ///
    /// WebTunnel is attempted first when the relay supports it; on failure the
    /// call falls through to obfs4 automatically.
    @discardableResult
    func start(relay: VeilRelay) throws -> UInt16 {
        stopIfRunning()

        // 1. WebTunnel
        if let wtPath = relay.wtPath, relay.tlsServerName != nil {
            let req = VeilTransportRequest.webTunnel(
                address:    relay.address,
                sni:        relay.tlsServerName ?? "",
                spki:       relay.pinnedSpki ?? "",
                hostHeader: relay.wtHostHeader ?? "",
                bridgeCert: relay.bridgeCert,
                wtBasePath: wtPath
            )
            if case .success(let p) = runtime.start(req) {
                commit(port: p, relay: relay, webTunnel: true)
                return p
            }
            // WebTunnel unavailable — fall through to obfs4
        }

        // 2. obfs4 (TLS-pinned / TLS-unpinned / plain)
        let req = obfs4Request(for: relay)
        switch runtime.start(req) {
        case .success(let p):
            commit(port: p, relay: relay, webTunnel: false)
            return p
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

    private func commit(port p: UInt16, relay: VeilRelay, webTunnel: Bool) {
        port = p
        currentRelay = relay
        isWebTunnel = webTunnel
    }

    private func stopIfRunning() {
        guard port != nil else { return }
        runtime.stop()
        port = nil
        currentRelay = nil
        isWebTunnel = false
    }

    private func obfs4Request(for relay: VeilRelay) -> VeilTransportRequest {
        if let sni = relay.tlsServerName {
            if let spki = relay.pinnedSpki {
                return .tlsPinned(bridgeLine: relay.bridgeLine, address: relay.address,
                                  sni: sni, spki: spki, profile: "chrome131")
            }
            return .tlsUnpinned(bridgeLine: relay.bridgeLine, address: relay.address, sni: sni)
        }
        return .plainObfs4(bridgeLine: relay.bridgeLine, address: relay.address)
    }
}
