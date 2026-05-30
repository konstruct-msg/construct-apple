//
//  ConnectionStatusEffector.swift
//  Construct Messenger
//
//  Concrete `UIEffector`. Updates the @MainActor mirror and surfaces auxiliary
//  signals (last successful RPC timestamp, last error string) to ConnectionStatusManager.
//  ConnectionStatusManager derives `connectionStatus` from the mirror itself — this
//  effector does not write status directly.
//

import Foundation

struct ConnectionStatusEffector: UIEffector {
    func publish(state: TransportState, event: TransportEvent, transition: TransitionLogEntry) async {
        await MainActor.run {
            TransportRouterMirror.shared.update(state: state, transition: transition)

            switch event {
            case .rpcSucceeded:
                ConnectionStatusManager.shared.markRequestSucceeded()
            case .rpcFailed(let kind, _, _) where kind.isTransportFailure:
                ConnectionStatusManager.shared.setLastError("transport: \(kind)")
            case .proxyStartFailed(_, let reason):
                ConnectionStatusManager.shared.setLastError(reason)
            default:
                break
            }
        }
    }
}
