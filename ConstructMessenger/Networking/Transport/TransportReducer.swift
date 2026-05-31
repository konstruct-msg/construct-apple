//
//  TransportReducer.swift
//  Construct Messenger
//
//  Pure FSM for the transport layer.
//
//  The reducer takes a state and an event, and returns the next state plus a list of
//  side-effects. It performs no I/O, reads no globals, and is fully deterministic given
//  the four inputs: (state, event, config, now).
//
//  All transport routing decisions in the app should be expressed by adding a case here,
//  not by mutating a singleton from a service.
//

import Foundation

enum TransportReducer {

    typealias Outcome = (state: TransportState, effects: [TransportEffect])

    /// The single entry point. Returns the next state and the effects to apply.
    static func reduce(
        state: TransportState,
        event: TransportEvent,
        config: TransportConfig = .default,
        now: Date
    ) -> Outcome {
        // Cross-state events that override per-state handling.
        switch event {
        case .networkPathChanged(let reachable, let censored, let mode):
            return reduceNetworkPathChanged(reachable: reachable, censored: censored, mode: mode)

        case .manualReset:
            return reduceManualReset(state: state)

        case .veilModeChanged(let mode, let censored):
            return reduceVEILModeChanged(state: state, mode: mode, censored: censored)

        case .veilConfigChanged:
            return reduceVEILConfigChanged(state: state)

        default:
            break
        }

        // Per-state handling.
        switch state {
        case .offline:
            // Ignore everything else until reachability comes back.
            return (state, [])

        case .direct(let fails):
            return reduceDirect(fails: fails, event: event, config: config, now: now)

        case .veilProbing(let attempt):
            return reduceProbing(attempt: attempt, event: event, config: config, now: now)

        case .veilActive(let relay, let port, let since):
            return reduceActive(relay: relay, port: port, since: since, event: event, config: config, now: now)

        case .veilDegraded(let relay, let port, let fails):
            return reduceDegraded(relay: relay, port: port, fails: fails, event: event, config: config, now: now)

        case .veilCooldown(let until):
            return reduceCooldown(until: until, event: event, config: config, now: now)
        }
    }

    // MARK: - Cross-state handlers

    private static func reduceNetworkPathChanged(reachable: Bool, censored: Bool, mode: VeilMode) -> Outcome {
        guard reachable else {
            return (.offline, [.requestProxyStop, .setVeilPort(nil), .invalidateGRPCClient])
        }
        // New path → recompute the starting state from current inputs, then tear down
        // everything stale and (if needed) kick a fresh VEIL probe.
        let initial = TransportState.initial(mode: mode, censored: censored, reachable: true)
        var effects: [TransportEffect] = [.requestProxyStop, .setVeilPort(nil), .invalidateGRPCClient]
        if case .veilProbing = initial { effects.append(.requestProxyStart) }
        return (initial, effects)
    }

    private static func reduceVEILConfigChanged(state: TransportState) -> Outcome {
        switch state {
        case .veilActive, .veilDegraded:
            // Active VEIL — drop the current proxy and probe again with the new config.
            return rotateRelay()
        case .veilProbing:
            // Already probing; let the in-flight start finish, then natural cycle picks new config.
            return (state, [])
        case .offline, .direct, .veilCooldown:
            return (state, [])
        }
    }

    private static func reduceManualReset(state: TransportState) -> Outcome {
        // Always end up in direct(0). User asked to start over.
        guard state != .direct(consecutiveFails: 0) else {
            return (state, [.invalidateGRPCClient])
        }
        return (.direct(consecutiveFails: 0), [.requestProxyStop, .setVeilPort(nil), .invalidateGRPCClient])
    }

    private static func reduceVEILModeChanged(state: TransportState, mode: VeilMode, censored: Bool) -> Outcome {
        // While offline (no network route) mode changes have no useful effect: any
        // transport attempt will fail-fast on DNS, burning the direct + probe budget
        // and dumping us into a 30s cooldown for nothing. Stay in .offline; the
        // current mode is reapplied via reduceNetworkPathChanged when reachability
        // returns and TransportState.initial is recomputed.
        if case .offline = state {
            return (state, [])
        }
        switch mode {
        case .off:
            return (.direct(consecutiveFails: 0), [.requestProxyStop, .setVeilPort(nil), .invalidateGRPCClient])
        case .on:
            switch state {
            case .veilActive, .veilDegraded, .veilProbing:
                return (state, [])
            default:
                return (.veilProbing(attempt: 1), [.requestProxyStart])
            }
        case .auto:
            // On a censored network the user toggling to .auto is an explicit request for
            // VEIL protection. Otherwise .auto means "stay on direct, escalate on failures."
            if censored {
                switch state {
                case .veilActive, .veilDegraded, .veilProbing:
                    return (state, [])
                default:
                    return (.veilProbing(attempt: 1), [.requestProxyStart])
                }
            }
            return (state, [])
        }
    }

    // MARK: - Per-state handlers

    private static func reduceDirect(fails: Int, event: TransportEvent, config: TransportConfig, now: Date) -> Outcome {
        switch event {
        case .rpcSucceeded:
            return (.direct(consecutiveFails: 0), [])

        case .rpcFailed(let kind, let via, let foreground):
            // Only count foreground transport failures over the direct path.
            guard foreground, !via.isVEIL, kind.isTransportFailure else {
                return (.direct(consecutiveFails: fails), [])
            }
            let newFails = fails + 1
            if newFails >= config.directFailThreshold {
                return (.veilProbing(attempt: 1), [.requestProxyStart, .invalidateGRPCClient])
            }
            return (.direct(consecutiveFails: newFails), [])

        case .proxyStarted(let relay, let port, let restarted):
            // Defensive: someone started VEIL while we thought we were direct. Adopt it.
            var effects: [TransportEffect] = [.setVeilPort(port)]
            if restarted { effects.append(.invalidateGRPCClient) }
            return (.veilActive(relay: relay, port: port, since: now), effects)

        default:
            return (.direct(consecutiveFails: fails), [])
        }
    }

    private static func reduceProbing(attempt: Int, event: TransportEvent, config: TransportConfig, now: Date) -> Outcome {
        switch event {
        case .proxyStarted(let relay, let port, let restarted):
            var effects: [TransportEffect] = [.setVeilPort(port)]
            if restarted { effects.append(.invalidateGRPCClient) }
            return (.veilActive(relay: relay, port: port, since: now), effects)

        case .proxyStartFailed:
            let nextAttempt = attempt + 1
            if nextAttempt > config.maxProbeAttempts {
                let until = now.addingTimeInterval(config.veilCooldownDuration)
                return (.veilCooldown(until: until), [.setVeilPort(nil), .scheduleCooldownEnd(at: until)])
            }
            return (.veilProbing(attempt: nextAttempt), [.requestProxyStart])

        default:
            // While probing we don't react to RPC events — the proxy isn't up yet.
            return (.veilProbing(attempt: attempt), [])
        }
    }

    private static func reduceActive(relay: String, port: UInt16, since: Date, event: TransportEvent, config: TransportConfig, now: Date) -> Outcome {
        switch event {
        case .rpcSucceeded:
            return (.veilActive(relay: relay, port: port, since: since), [])

        case .rpcFailed(let kind, let via, let foreground):
            guard foreground, via.isVEIL, kind.isTransportFailure else {
                return (.veilActive(relay: relay, port: port, since: since), [])
            }
            // Hard relay failures (observable DPI block, cert expiry, dead local proxy):
            // the relay is broken. Rotate immediately.
            if isHardRelayFailure(kind) {
                return rotateRelay()
            }
            // Soft failures (random stream reset, generic transportUnknown / streamTimeout):
            // the TCP socket got RST'd but the obfs4 tunnel may still be alive. Restarting
            // the Rust proxy is expensive (8-13s of downtime, kills working tunnel state)
            // and pointless when there's only one usable relay anyway. Just invalidate the
            // gRPC client; the next RPC reconnects through the same proxy port.
            return (.veilActive(relay: relay, port: port, since: since), [.invalidateGRPCClient])

        default:
            return (.veilActive(relay: relay, port: port, since: since), [])
        }
    }

    private static func reduceDegraded(relay: String, port: UInt16, fails: Int, event: TransportEvent, config: TransportConfig, now: Date) -> Outcome {
        switch event {
        case .rpcSucceeded:
            // Recovered. Reset to active with a fresh `since`.
            return (.veilActive(relay: relay, port: port, since: now), [])

        case .rpcFailed(let kind, let via, let foreground):
            guard foreground, via.isVEIL, kind.isTransportFailure else {
                return (.veilDegraded(relay: relay, port: port, consecutiveFails: fails), [])
            }
            if isHardRelayFailure(kind) {
                return rotateRelay()
            }
            // Soft failure in degraded — same logic as active: recycle the gRPC client,
            // keep the proxy. Move back to veilActive so success will re-mark Connected.
            return (.veilActive(relay: relay, port: port, since: now), [.invalidateGRPCClient])

        default:
            return (.veilDegraded(relay: relay, port: port, consecutiveFails: fails), [])
        }
    }

    // MARK: - Helpers

    /// A relay failure that means "this relay is observably broken right now" —
    /// don't waste another RPC trying to confirm. Rotate.
    private static func isHardRelayFailure(_ kind: RPCFailureKind) -> Bool {
        switch kind {
        case .staleLocalProxy,
             .webTunnelBlocked,
             .tlsCertExpired,
             .tlsFingerprintBlocked:
            return true
        case .streamTimeout, .transportUnknown,
             .authRejected, .applicationError, .transientCancellation:
            return false
        }
    }

    /// Effects for "stop current proxy, drop port + grpc client, start a fresh probe."
    private static func rotateRelay() -> Outcome {
        return (.veilProbing(attempt: 1),
                [.requestProxyStop, .setVeilPort(nil), .requestProxyStart, .invalidateGRPCClient])
    }

    private static func reduceCooldown(until: Date, event: TransportEvent, config: TransportConfig, now: Date) -> Outcome {
        switch event {
        case .cooldownElapsed:
            return (.direct(consecutiveFails: 0), [.invalidateGRPCClient])
        default:
            // Cooldown swallows all events. The router schedules the elapsed event itself.
            return (.veilCooldown(until: until), [])
        }
    }
}

// MARK: - Convenience for logging

extension TransportEvent {
    /// Short label for use in transition log entries.
    var shortLabel: String {
        switch self {
        case .rpcSucceeded(let via, let ms):
            return "rpc-ok(via=\(via.isVEIL ? "veil" : "direct"), \(ms)ms)"
        case .rpcFailed(let kind, let via, let fg):
            return "rpc-fail(kind=\(kind), via=\(via.isVEIL ? "veil" : "direct"), fg=\(fg))"
        case .networkPathChanged(let r, let c, let m):
            return "network-path(reachable=\(r), censored=\(c), mode=\(m.rawValue))"
        case .veilModeChanged(let m, let c):
            return "veil-mode(\(m.rawValue)\(c ? ",censored" : ""))"
        case .veilConfigChanged:
            return "veil-config-changed"
        case .proxyStarted(let r, let p, let restarted):
            return "proxy-started(\(r):\(p)\(restarted ? ",new" : ",reuse"))"
        case .proxyStartFailed(let r, let why):
            return "proxy-failed(\(r ?? "?"): \(why))"
        case .cooldownElapsed:
            return "cooldown-elapsed"
        case .manualReset:
            return "manual-reset"
        }
    }
}

extension TransportEffect {
    /// Short label for use in transition log entries.
    var shortLabel: String {
        switch self {
        case .invalidateGRPCClient:           return "invalidate-grpc"
        case .setVeilPort(let p):              return "set-veil-port(\(p.map(String.init) ?? "nil"))"
        case .requestProxyStart:              return "start-proxy"
        case .requestProxyStop:               return "stop-proxy"
        case .scheduleCooldownEnd(let d):     return "schedule-cooldown(\(Int(d.timeIntervalSinceNow))s)"
        }
    }
}
