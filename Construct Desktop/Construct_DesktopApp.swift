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

    @State private var authViewModel     = AuthViewModel(context: PersistenceController.shared.container.viewContext)
    @State private var chatsViewModel    = ChatsViewModel()
    @State private var securityViewModel = SecurityViewModel()
    @State private var recoveryViewModel = AccountRecoveryViewModel()
    @State private var deepLinkHandler   = DeepLinkHandler()

    // Command bridge — owned here, wired up in DesktopRootView
    @State private var commandBridge = DesktopCommandBridge()

    init() {
        // Set UNUserNotificationCenterDelegate for macOS so foreground notifications
        // show as banners. On iOS this is handled by PushNotificationManager.
        UNUserNotificationCenter.current().delegate = LocalNotificationManager.shared
    }

    var body: some Scene {
        // MARK: - Main window
        WindowGroup {
            DesktopRootView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .environment(authViewModel)
                .environment(chatsViewModel)
                .environment(securityViewModel)
                .environment(recoveryViewModel)
                .environment(deepLinkHandler)
                .environment(\.commandBridge, commandBridge)
                .task {
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    chatsViewModel.setContext(PersistenceController.shared.container.viewContext)
                    // Start QUIC engine — macOS has no UDP 443 OS restriction (unlike iOS).
                    do { try EngineAdapter.shared.start() } catch {
                        Log.error("Engine start failed: \(error)", category: "Engine")
                    }
                    await IceProxyManager.shared.startIfEnabled()
                    if authViewModel.isAuthenticated,
                       let deviceId = KeychainManager.shared.loadDeviceID() {
                        await PQCKeyManager.migrateIfNeeded(deviceId: deviceId)
                    }
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                }
        }
        .commands {
            ConstructCommands(bridge: commandBridge)
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
