//
//  AppActivityState.swift
//  Construct Messenger
//
//  Thread-safe, nonisolated snapshot of whether the app is foreground-active.
//

#if canImport(UIKit)
import UIKit
#endif
import Foundation

/// A cheap, lock-guarded snapshot of the app's foreground/active state, readable from any
/// isolation domain.
///
/// The transport layer runs off the main actor (`GRPCCallExecutor`, gRPC NIO threads) and needs
/// to know app state to avoid futile work. The motivating case: when a VEIL RPC fails with
/// `staleLocalProxy` (the local Rust proxy's TCP listener is gone), the FSM normally rotates the
/// relay — but if iOS has suspended the app in the background, it has also frozen the Rust runtime
/// and reclaimed that socket. Restarting the proxy there just spins up a session that will be
/// re-suspended within seconds, producing the observed reconnect churn. The reducer already guards
/// its rotate/escalate paths on a `foreground` flag; this type provides the real value for it
/// (previously hardcoded `true`).
///
/// Reading `UIApplication.applicationState` requires the main actor, so we cache it behind a lock
/// and refresh it from lifecycle notifications. `.active` → foreground; `.inactive` (transient
/// system UI, incoming-call banner) and `.background` → not foreground, which is the conservative,
/// churn-suppressing choice.
final class AppActivityState: @unchecked Sendable {
    static let shared = AppActivityState()

    private let lock = NSLock()
    private var _isForeground: Bool

    private init() {
        // App launches active; corrected by the first lifecycle notification. macOS has no
        // suspension model, so it stays foreground (the observers below are iOS-only).
        _isForeground = true
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleInactive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleInactive),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif
    }

    /// True when the app is foreground-active; false when inactive or backgrounded.
    var isForeground: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isForeground
    }

    private func set(_ value: Bool) {
        lock.lock(); _isForeground = value; lock.unlock()
    }

    #if canImport(UIKit)
    @objc private func handleActive()   { set(true) }
    @objc private func handleInactive() { set(false) }
    #endif
}
