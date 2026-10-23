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

/// Scene identifiers for secondary Desktop windows (D2).
enum DesktopWindowID {
    static let synaps = "synaps"
    static let call = "call"
}

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
        // Every front this install knows leaves the logs before the first line could name one.
        LogRedaction.registerKnownFronts()
        // The store first: every repository stands on it, and a failure must be known before the
        // first screen and before the stream writes anything (`DesktopRootView`).
        LocalRepositories.openAppStoreIfNeeded()
        // What Core Data builds left, in the clear. Sandboxed only: unsandboxed, Application
        // Support is the user's own and shared with other apps (`LocalDataWipe` refuses it too).
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            PersistenceController.removeLegacyStore(in: support)
        }

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
                    let viewContext = PersistenceController.shared.container.viewContext
                    chatsViewModel.setContext(viewContext)

                    MediaManager.shared.evictOldFiles()
                // Packs that ship in the app, into the store once. No network; first launch only.
                StickerService.shared.seedBundledPacks()
                    StorageMigrationService.shared.migrateIfNeeded(context: viewContext)
                    // Media from before 2026-09-30 lies in the clear in the container; seal it.
                    Task.detached(priority: .utility) { MediaManager.sealClearFiles() }
                    Log.debug("Desktop launch bootstrap — storage migration complete", category: "Desktop")

                    // Direct path (Strategy B): construct-core (UniFFI) + gRPC-Swift + VEIL from core.
                    // Engine layer is paused for Desktop.
                    await VeilProxyManager.shared.startIfNeeded()
                    await TransportRouter.shared.bootstrap()

                    // Post-auth key maintenance lives in AuthViewModel; this task can run before
                    // async session restore completes.
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])

                    // Calls on Desktop since 2026-10-21; no CallKit, WebRTC drives Core Audio itself.
                    if CallsFeature.isEnabled {
                        #if canImport(WebRTC)
                        WebRTCRuntime.bootstrap()
                        CallManager.makeStudioCapture = StudioProcessTap.make
                        CallManager.makeStudioOutput = StudioPlayoutOutput.make
                        #endif
                        DesktopIncomingCallRinger.shared.start()
                    }

                    // Touch STT early on Desktop too so WhisperModelManager runs reconcileModels()
                    // (recovers models after app updates / reinstalls).
                    #if canImport(WhisperKit)
                    _ = VoiceTranscriptionService.shared.isAvailable
                    #endif
                }
        }
        // Native titlebar + unified toolbar (D1). Hidden titlebar was how the iOS
        // glass chat nav sat flush to the traffic lights; the toolbar now owns that slot.
        .windowToolbarStyle(.unified)
        .commands {
            ConstructCommands(bridge: commandBridge)
        }

        // Synapses is its own window — not a tab that replaces the open chat (D2).
        Window(LocalizedStringKey("synapses"), id: DesktopWindowID.synaps) {
            DesktopSynapsView()
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .environment(chatsViewModel)
                .environment(authViewModel)
                .environment(deepLinkHandler)
                .frame(minWidth: 560, minHeight: 440)
        }
        .defaultSize(width: 720, height: 560)
        .windowToolbarStyle(.unified)

        // The call's own window (design: claude.ai/artifact/NjvFrSAuKZxc43tqxRJHdj). Opened by
        // DesktopRootView when a call starts or is answered; closes itself when the call is over.
        Window(LocalizedStringKey("call_window_title"), id: DesktopWindowID.call) {
            DesktopCallWindowView(model: DesktopCallModel.shared)
        }
        .defaultSize(width: 440, height: 600)
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)

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
