//
//  IceProxy.swift
//  Construct Messenger
//
//  Serial actor managing the lifecycle of the local Rust ICE proxy process.
//
//  Replaces the proxy start/stop/restart state machine scattered across
//  IceProxyManager. The actor executor serialises all calls — no generation
//  counters, crash-restart flags, or resetAllProxyState() needed.
//
//  Transport selection priority (same as before):
//    1. WebTunnel (ICE v2) when relay has wtPath + tlsServerName
//    2. obfs4 inside TLS with SPKI pinning when tlsServerName + pinnedSpki present
//    3. obfs4 inside TLS (CA chain) when tlsServerName present
//    4. Plain obfs4 (no TLS wrapper)
//

import Foundation

// MARK: - Error

enum IceProxyError: Error, Sendable {
    /// Rust FFI returned a non-zero code.
    case startFailed(underlying: IceProxyRuntimeError)

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
actor IceProxy {

    // MARK: - State

    /// Local port the Rust proxy is listening on, or nil when stopped.
    private(set) var port: UInt16?

    /// Relay the proxy is currently running for.
    private(set) var currentRelay: IceRelay?

    /// Whether the active transport is WebTunnel (true) or obfs4 (false).
    private(set) var isWebTunnel: Bool = false

    private let runtime: IceProxyRuntime

    // MARK: - Init

    init(runtime: IceProxyRuntime = NativeIceProxyRuntime()) {
        self.runtime = runtime
    }

    // MARK: - Public API

    /// Returns the current port if `relay` is already running.
    /// Restarts the proxy for `relay` otherwise.
    @discardableResult
    func ensure(relay: IceRelay) throws -> UInt16 {
        if let p = port, currentRelay?.address == relay.address { return p }
        return try start(relay: relay)
    }

    /// Starts the proxy for `relay`, stopping any currently running proxy first.
    ///
    /// WebTunnel is attempted first when the relay supports it; on failure the
    /// call falls through to obfs4 automatically.
    @discardableResult
    func start(relay: IceRelay) throws -> UInt16 {
        stopIfRunning()

        // 1. WebTunnel
        if let wtPath = relay.wtPath, relay.tlsServerName != nil {
            let req = IceTransportRequest.webTunnel(
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
            throw IceProxyError.startFailed(underlying: err)
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

    private func commit(port p: UInt16, relay: IceRelay, webTunnel: Bool) {
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

    private func obfs4Request(for relay: IceRelay) -> IceTransportRequest {
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
