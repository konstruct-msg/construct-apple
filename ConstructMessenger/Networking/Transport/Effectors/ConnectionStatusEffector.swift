//
//  ConnectionStatusEffector.swift
//  Construct Messenger
//
//  Concrete `UIEffector`. Updates the @MainActor mirror and forwards a coarse
//  status to the legacy `ConnectionStatusManager` so existing UI surfaces keep
//  rendering until they migrate to observing `TransportRouterMirror` directly.
//

import Foundation

struct ConnectionStatusEffector: UIEffector {
    func publish(state: TransportState, event: TransportEvent, transition: TransitionLogEntry) async {
        await MainActor.run {
            TransportRouterMirror.shared.update(state: state, transition: transition)
            forwardLegacyStatus(state: state, event: event)
        }
    }

    /// Bridge into the legacy ConnectionStatusManager so views that read it during
    /// the migration still see sensible status text. Removed once those views
    /// observe `TransportRouterMirror` directly.
    @MainActor
    private func forwardLegacyStatus(state: TransportState, event: TransportEvent) {
        // Any successful foreground RPC is the strongest signal that we're working —
        // beat all other state-derived rules. This is what users see as "Connected".
        if case .rpcSucceeded = event {
            ConnectionStatusManager.shared.markRequestSucceeded()
            return
        }

        switch state {
        case .offline:
            ConnectionStatusManager.shared.markStreamDisconnected(error: "offline")
        case .direct(let fails) where fails > 0:
            ConnectionStatusManager.shared.markConnecting(phase: "retry direct (\(fails))")
        case .direct:
            // Fresh direct path — stay in the previous status (likely Connecting on cold start;
            // first rpcSucceeded above will flip to Connected). Don't reset to Connecting here
            // or every "stay in direct(0)" event would loop status back to connecting.
            break
        case .veilProbing(let attempt):
            ConnectionStatusManager.shared.markConnecting(phase: "ICE probe \(attempt)")
        case .veilActive(let relay, _, _):
            // The FSM is in active state. If we got here via proxyStarted (no traffic yet)
            // stay in Connecting until the first rpcSucceeded; if we got here via rpc-ok the
            // early-return above already flipped to Connected.
            if case .proxyStarted = event {
                ConnectionStatusManager.shared.markConnecting(phase: "ICE active (\(relay))")
            }
        case .veilDegraded(let relay, _, let fails):
            ConnectionStatusManager.shared.markConnecting(phase: "ICE degraded \(relay) (\(fails))")
        case .veilCooldown:
            ConnectionStatusManager.shared.markStreamDisconnected(error: "ICE cooldown")
        }
    }
}
