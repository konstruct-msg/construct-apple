//
//  Construct_DesktopApp.swift
//  Construct Desktop
//
//  macOS native entry point.
//  Shares Core Data stack, ViewModels and Services with the iOS target.
//

import SwiftUI
import CoreData

@main
struct Construct_DesktopApp: App {

    @State private var authViewModel = AuthViewModel(context: PersistenceController.shared.container.viewContext)
    @State private var chatsViewModel = ChatsViewModel()
    @State private var securityViewModel = SecurityViewModel()

    var body: some Scene {
        // MARK: - Main window
        WindowGroup {
            DesktopRootView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .environment(authViewModel)
                .environment(chatsViewModel)
                .environment(securityViewModel)
                .task {
                    chatsViewModel.setContext(PersistenceController.shared.container.viewContext)
                    await IceProxyManager.shared.startIfEnabled()
                    if authViewModel.isAuthenticated,
                       let deviceId = KeychainManager.shared.loadDeviceID() {
                        await PQCKeyManager.migrateIfNeeded(deviceId: deviceId)
                    }
                }
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

