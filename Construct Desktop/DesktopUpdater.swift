//
//  DesktopUpdater.swift
//  Construct Desktop
//
//  Sparkle: checks the feed for this architecture once a day and offers a new build, which it
//  installs only when the DMG's EdDSA signature verifies against `SUPublicEDKey`. Off where
//  Info.plist says so (Debug, and Release until it has a feed of its own).
//

import Foundation
import Sparkle

@MainActor
@Observable
final class DesktopUpdater: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false

    var isEnabled: Bool { controller != nil }

    override init() {
        super.init()
        guard DesktopUpdateFeed.isEnabled(infoValue: Bundle.main.object(forInfoDictionaryKey: "KonstructUpdatesEnabled")) else {
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let can = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        DesktopUpdateFeed.url(for: DesktopUpdateFeed.current).absoluteString
    }
}
