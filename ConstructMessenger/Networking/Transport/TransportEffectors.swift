//
//  TransportEffectors.swift
//  Construct Messenger
//
//  Side-effect interfaces that the TransportRouter applies in response to FSM effects.
//  Each effector is small, focused, and Sendable so the router can hold it across
//  actor hops without ceremony. Concrete implementations live in the `Effectors/` folder.
//

import Foundation

// MARK: - Proxy effector

/// Drives the local VEIL proxy on behalf of the FSM. Owns relay selection and the
/// VeilProxy actor; the router only knows "start" and "stop".
protocol ProxyEffector: Sendable {
    /// Bring up the proxy for the best currently-available relay.
    /// Returns the outcome as a `TransportEvent` ready to be fed back into the router.
    /// Implementations MUST return one of: `.proxyStarted(...)` or `.proxyStartFailed(...)`.
    func start() async -> TransportEvent

    /// Tear down the proxy unconditionally. No-op if already stopped.
    func stop() async

    /// Replace the relay candidate set (e.g. after a manifest refresh from the server).
    func updateRelays(_ relays: [VeilRelay]) async
}

// MARK: - Channel effector

/// Drives the gRPC client lifecycle on behalf of the FSM.
protocol ChannelEffector: Sendable {
    /// Force the persistent gRPC client to be re-created on the next RPC.
    func invalidateClient() async

    /// Configure the local VEIL proxy port (nil to clear / use direct).
    func setVeilPort(_ port: UInt16?) async
}

// MARK: - UI effector

/// Publishes router state into a form the SwiftUI layer can observe.
protocol UIEffector: Sendable {
    /// Called after every transition so the UI mirror stays in sync. The event is included
    /// so the effector can distinguish "FSM is in veilActive because traffic just succeeded"
    /// (mark UI as Connected) from "FSM moved to veilActive because proxy just started but
    /// no traffic yet" (still Connecting until the first rpc-ok).
    func publish(state: TransportState, event: TransportEvent, transition: TransitionLogEntry) async
}
