//
//  DesktopBackground.swift
//  Construct Desktop
//
//  Konstruct Desktop keeps running with its window closed. A Mac gets no push for Konstruct, so
//  the message stream is the only way a message arrives (vault todo 107): the stream belongs to
//  the app, not the window, and the app stays until the user quits it. A click on the Dock icon
//  opens the window again. "Open at login" (`DesktopLoginItemController`) covers a restart.
//

import AppKit
import ServiceManagement

final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    /// Said explicitly rather than left to SwiftUI's default: quitting with the last window would
    /// stop delivery, and nothing on a Mac would bring it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
@Observable
final class DesktopLoginItemController {
    private(set) var row = DesktopLoginItem.row(for: .notRegistered)

    init() { refresh() }

    func refresh() {
        row = DesktopLoginItem.row(for: Self.status(SMAppService.mainApp.status))
    }

    func setOn(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("Login item \(on ? "register" : "unregister") failed: \(error)", category: "App")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func status(_ status: SMAppService.Status) -> DesktopLoginItem.Status {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }
}
