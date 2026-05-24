//
//  ConnectionManager.swift
//  Construct Messenger
//
//  UI-facing facade for ICE proxy state. Views and view-models use this
//  instead of IceProxyManager directly, keeping the protocol boundary narrow.
//
//  All property reads forward to IceProxyManager; objectWillChange is piped
//  through so SwiftUI re-renders whenever IceProxyManager publishes a change.
//

import Foundation
import Combine

@MainActor
final class ConnectionManager: ObservableObject {

    static let shared = ConnectionManager()

    private var cancellables = Set<AnyCancellable>()

    private init() {
        IceProxyManager.shared.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - State (forwarded)

    var isRunning: Bool { IceProxyManager.shared.isRunning }
    var isOnCooldown: Bool { IceProxyManager.shared.isOnCooldown }
    var activeRelay: IceRelay? { IceProxyManager.shared.activeRelay }
    var isWebTunnel: Bool { IceProxyManager.shared.isWebTunnelActive }
    var lastError: String? { IceProxyManager.shared.lastError }
    var hasCert: Bool { IceProxyManager.shared.hasCert }
    var currentTrafficPath: TrafficPath { IceProxyManager.shared.currentTrafficPath }

    var mode: IceMode {
        get { IceProxyManager.shared.mode }
        set { IceProxyManager.shared.mode = newValue }
    }

    func qualityForRelay(_ address: String) -> RelayQuality {
        IceProxyManager.shared.qualityForRelay(address)
    }

    // MARK: - Actions (forwarded)

    func startIfEnabled() async {
        await IceProxyManager.shared.startIfEnabled()
    }

    func verifyAliveOrRestart() async {
        await IceProxyManager.shared.verifyAliveOrRestart()
    }

    func stop() {
        IceProxyManager.shared.stop()
    }

    func clearCooldown() {
        IceProxyManager.shared.clearCooldown()
    }

    func configureFromServer(cert: String) {
        IceProxyManager.shared.configureFromServer(cert: cert)
    }
}
