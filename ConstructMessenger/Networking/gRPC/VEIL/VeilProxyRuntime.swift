//
//  VeilProxyRuntime.swift
//  Construct Messenger
//
//  Narrow protocol isolating all `veil_proxy_*` C FFI symbols from policy logic.
//
//  The runtime owns **no** policy — it does not know about VEIL mode, DPI detection,
//  cooldowns, relay quality scores, or gRPC. `VeilProxyManager` decides which transport
//  to start; the runtime executes the C call and returns a typed result.
//
//  Conforming to `Sendable` allows the runtime to be referenced from nonisolated
//  contexts (e.g. test mocks, future async wrappers).
//

import Foundation

/// Contract for the native VEIL proxy C FFI layer.
///
/// Production path goes through the unified `veil_start` FFI (Rust does parallel
/// happy-eyeballs probing of obfs4 + WebTunnel internally and picks a winner).
/// The legacy per-method `start(_:)` / `startSecondary` calls remain on the protocol
/// for test ergonomics — production code paths must not use them.
protocol VeilProxyRuntime: AnyObject, Sendable {
    /// Unified entry point — Rust coordinator picks the obfuscator via happy-eyeballs.
    /// Returns the local port, the winning method, and the probe latency.
    func startUnified(
        relay: VeilRelay,
        fingerprint: Data,
        scoresPath: String?
    ) -> Result<VeilStartOutcome, VeilProxyRuntimeError>

    /// Legacy per-method start. Kept for test mocks; production callers use `startUnified`.
    func start(_ request: VeilTransportRequest) -> Result<UInt16, VeilProxyRuntimeError>

    /// Legacy secondary start for Happy Eyeballs dual-proxy mode. Kept for test mocks.
    func startSecondary(bridgeLine: String, address: String) -> Result<UInt16, VeilProxyRuntimeError>

    /// Stop the active proxy (regardless of which start variant was used).
    func stop()

    /// Whether the Rust proxy process is currently alive.
    func isAlive() -> Bool
}
