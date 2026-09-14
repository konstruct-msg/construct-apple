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
        // Foreground-state tracker — transport layer reads this to suppress futile VEIL
        // restarts while the app is inactive (mirrors iOS AppDelegate bootstrap).
        _ = AppActivityState.shared

        // Set UNUserNotificationCenterDelegate for macOS so foreground notifications
        // show as banners. On iOS this is handled by PushNotificationManager.
        UNUserNotificationCenter.current().delegate = LocalNotificationManager.shared

        // Default to more compact text on macOS Desktop (user can change in Settings/Appearance)
        if UserDefaults.standard.string(forKey: "textSize") == nil {
            UserDefaults.standard.set("compact", forKey: "textSize")
        }
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
                    if PreviewDetector.isRunningInPreview { return }

                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    let viewContext = PersistenceController.shared.container.viewContext
                    chatsViewModel.setContext(viewContext)

                    MediaManager.shared.evictOldFiles()
                    StorageMigrationService.shared.migrateIfNeeded(context: viewContext)
                    Log.debug("Desktop launch bootstrap — storage migration complete", category: "Desktop")

                    // Direct path (Strategy B): construct-core (UniFFI) + gRPC-Swift + VEIL from core.
                    // Engine layer is paused for Desktop.
                    await VeilProxyManager.shared.startIfEnabled()
                    await TransportRouter.shared.bootstrap()

                    // Post-auth key maintenance lives in AuthViewModel; this task can run before
                    // async session restore completes.
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])

                    // Calls remain iOS-only while the protocol is being stabilized.
                    if CallsFeature.isEnabled {
                        #if canImport(WebRTC)
                        WebRTCRuntime.bootstrap()
                        #endif
                    }

                    // Touch STT early on Desktop too so WhisperModelManager runs reconcileModels()
                    // (recovers models after app updates / reinstalls).
                    #if canImport(WhisperKit)
                    _ = VoiceTranscriptionService.shared.isAvailable
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
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
