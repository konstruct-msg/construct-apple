//
//  Construct_DesktopApp.swift
//  Construct Desktop
//
//  macOS native entry point.
//  Shares Core Data stack, ViewModels and Services with the iOS target.
//  Platform-specific code is guarded with #if os(macOS) / #if os(iOS).
//

import SwiftUI
import CoreData

@main
struct Construct_DesktopApp: App {

    var body: some Scene {
        // MARK: - Main window
        WindowGroup {
            DesktopRootView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
        .commands {
            // Remove "New Window" shortcut — messenger is single-window
            CommandGroup(replacing: .newItem) {}
        }

        // MARK: - macOS Settings window (⌘,)
        Settings {
            DesktopSettingsView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
        }
    }
}

