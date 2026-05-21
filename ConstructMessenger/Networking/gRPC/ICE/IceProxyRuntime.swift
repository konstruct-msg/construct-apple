//
//  IceProxyRuntime.swift
//  Construct Messenger
//
//  Narrow protocol isolating all `ice_proxy_*` C FFI symbols from policy logic.
//
//  The runtime owns **no** policy — it does not know about ICE mode, DPI detection,
//  cooldowns, relay quality scores, or gRPC. `IceProxyManager` decides which transport
//  to start; the runtime executes the C call and returns a typed result.
//
//  Conforming to `Sendable` allows the runtime to be referenced from nonisolated
//  contexts (e.g. test mocks, future async wrappers).
//

import Foundation

/// Contract for the native ICE proxy C FFI layer.
///
/// Wraps the six `ice_proxy_*` symbols exported by `libconstruct_core`:
///   `ice_proxy_start`, `ice_proxy_start_tls`, `ice_proxy_start_tls_profiled`,
///   `ice_proxy_start_webtunnel`, `ice_proxy_stop`, `ice_proxy_is_running`.
protocol IceProxyRuntime: AnyObject, Sendable {
    /// Start the primary proxy with the given transport configuration.
    /// Returns the bound local port on success.
    func start(_ request: IceTransportRequest) -> Result<UInt16, IceProxyRuntimeError>

    /// Start the secondary (plain obfs4) proxy for Happy Eyeballs dual-proxy mode.
    ///
    /// The secondary targets the `PROXY` Rust static, which does not collide with
    /// a concurrently running `PROXY_TLS` primary.
    func startSecondary(bridgeLine: String, address: String) -> Result<UInt16, IceProxyRuntimeError>

    /// Stop the primary proxy.
    func stop()

    /// Whether the Rust proxy process is currently alive.
    ///
    /// Queries the native flag directly — the Swift `isRunning` state can be stale
    /// after the OS kills background threads while the app is suspended.
    func isAlive() -> Bool
}
