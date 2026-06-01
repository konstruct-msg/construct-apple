//
//  TransportRouterMirror.swift
//  Construct Messenger
//
//  Main-actor observable surface for the transport router.
//
//  The router itself is an actor — SwiftUI cannot observe actor state directly. This
//  mirror is a tiny @MainActor @Observable class that the router pushes updates to.
//  Views observe this object; the actor remains the single owner of the FSM state.
//

import Foundation

@MainActor
@Observable
final class TransportRouterMirror {
    static let shared = TransportRouterMirror()

    /// Current FSM state. Updated immediately after every transition.
    private(set) var state: TransportState = .offline

    /// Last N transitions, newest at the end. Used by the debug Transport Diagnostics screen
    /// and dumped into support logs.
    private(set) var recentTransitions: [TransitionLogEntry] = []

    /// Number of transitions retained in the ring buffer.
    private let maxTransitions = 100

    /// True while the mirror has at least one transition recorded.
    var hasHistory: Bool { !recentTransitions.isEmpty }

    /// True when the active transport is ICE (any sub-state).
    var isUsingVEIL: Bool { state.prefersVEIL && state.veilPort != nil }

    /// Most recent transition, if any.
    var latestTransition: TransitionLogEntry? { recentTransitions.last }

    nonisolated private init() {}

    func update(state: TransportState, transition: TransitionLogEntry) {
        self.state = state
        recentTransitions.append(transition)
        if recentTransitions.count > maxTransitions {
            recentTransitions.removeFirst(recentTransitions.count - maxTransitions)
        }
    }

    /// Clears the transition history. Useful for the debug screen.
    func clearHistory() {
        recentTransitions.removeAll(keepingCapacity: true)
    }
}
