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
/// One start: the unified `veil_start` FFI (Rust does parallel happy-eyeballs probing of the
/// obfuscators internally and picks a winner). The per-method `start(_:)` / `startSecondary`
/// pair of the Swift dual-proxy era was removed on 2026-10-20 with no production caller left.
protocol VeilProxyRuntime: AnyObject, Sendable {
    /// Unified entry point — Rust coordinator picks the obfuscator via happy-eyeballs.
    /// Returns the local port, the winning method, and the probe latency.
    func startUnified(
        relay: VeilRelay,
        fingerprint: Data,
        scoresPath: String?
    ) -> Result<VeilStartOutcome, VeilProxyRuntimeError>

    /// Stop the active proxy (regardless of which start variant was used).
    func stop()
}
