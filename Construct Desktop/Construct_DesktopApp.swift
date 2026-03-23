//
//  Construct_DesktopApp.swift
//  Construct Desktop
//
//  macOS native entry point.
//  Shares Core Data stack, ViewModels and Services with the iOS target.
//

import SwiftUI
import CoreData
import UserNotifications

@main
struct Construct_DesktopApp: App {

    @State private var authViewModel = AuthViewModel(context: PersistenceController.shared.container.viewContext)
    @State private var chatsViewModel = ChatsViewModel()
    @State private var securityViewModel = SecurityViewModel()
    @State private var recoveryViewModel = AccountRecoveryViewModel()

    var body: some Scene {
        // MARK: - Main window
        WindowGroup {
            DesktopRootView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .environment(authViewModel)
                .environment(chatsViewModel)
                .environment(securityViewModel)
                .environment(recoveryViewModel)
                .task {
                    chatsViewModel.setContext(PersistenceController.shared.container.viewContext)
                    await IceProxyManager.shared.startIfEnabled()
                    if authViewModel.isAuthenticated,
                       let deviceId = KeychainManager.shared.loadDeviceID() {
                        await PQCKeyManager.migrateIfNeeded(deviceId: deviceId)
                    }
                    // Request local notification permission for macOS desktop alerts
                    try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                }
        }
        .commands {
            // Replace default "New Window" with "New Chat" (⌘N)
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    chatsViewModel.showNewChat = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Add Find in sidebar (⌘F)
            CommandGroup(after: .sidebar) {
                Button("Find Chat") {
                    chatsViewModel.sidebarSearchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        // MARK: - macOS Settings window (⌘,)
        Settings {
            DesktopSettingsView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .environment(authViewModel)
                .environment(securityViewModel)
                .environment(recoveryViewModel)
        }
    }
}

