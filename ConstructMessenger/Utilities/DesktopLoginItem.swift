//
//  DesktopLoginItem.swift
//  Construct Messenger
//
//  "Open at login" on Konstruct Desktop. A Mac has no push for Konstruct (vault todo 107):
//  messages arrive only while the process runs, so closing the window keeps it running, and this
//  setting makes it run after a restart too. The system owns the state (`SMAppService.mainApp`);
//  this is how the setting reads it.
//
//  Pure, and in the shared folder so the iOS test target can test it; only Desktop calls it.
//

import Foundation

enum DesktopLoginItem {
    /// `SMAppService.Status`, without importing ServiceManagement into the shared folder.
    enum Status: Equatable {
        case enabled
        case notRegistered
        /// Registered, but the user turned it off in System Settings → Login Items, or has not
        /// approved it yet: it will not run until they do.
        case requiresApproval
        case notFound
    }

    struct Row: Equatable {
        let isOn: Bool
        /// Say that System Settings must allow it, and offer to open them.
        let needsApproval: Bool
    }

    static func row(for status: Status) -> Row {
        switch status {
        case .enabled: Row(isOn: true, needsApproval: false)
        case .requiresApproval: Row(isOn: true, needsApproval: true)
        case .notRegistered, .notFound: Row(isOn: false, needsApproval: false)
        }
    }
}
