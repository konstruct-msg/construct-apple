//
//  DiagnosticLogShare.swift
//  Construct Messenger
//
//  Single entry point for sharing the diagnostic log archive. Reused by
//  DiagnosticsView (logged-in Settings) AND the pre-login onboarding / recovery
//  flows — logs are collected unconditionally (LogCollector.isEnabled == true),
//  but until now the only way to export them was buried behind login + Settings.
//  A failed account recovery could not be diagnosed because the user never got
//  past login. This helper breaks that catch-22.
//

import Foundation

#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum DiagnosticLogShare {
    /// Build the rotating-log archive and present a system share sheet.
    /// - Parameter sourceView: optional popover anchor (iPad); centered when nil.
    static func present(sourceView: PlatformSourceView? = nil) {
        guard let url = try? LogCollector.shared.createLogArchive() else {
            Log.error("Failed to create log archive for sharing", category: "Diagnostics")
            return
        }
#if canImport(UIKit)
        // Must use ActivityShare on iPad — bare present() crashes without a popover source.
        ActivityShare.present(items: [url], sourceView: sourceView)
#elseif os(macOS)
        NSSharingServicePicker(items: [url])
            .show(relativeTo: .zero, of: sourceView ?? NSApp.keyWindow?.contentView ?? NSView(),
                  preferredEdge: .minY)
#endif
    }
}

#if canImport(UIKit)
typealias PlatformSourceView = UIView
#elseif os(macOS)
typealias PlatformSourceView = NSView
#endif
