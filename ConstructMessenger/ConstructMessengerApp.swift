//
//  ConstructMessengerApp.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//
// The iOS entry point. `Construct Desktop` compiles this whole group, so without this guard
// the target has two `@main` structs and no amount of linker luck resolves that.
#if os(iOS)

import SwiftUI
import CoreData
import UIKit

@main
struct Construct_MessengerApp: App {
    // IMPORTANT: AppDelegate for background tasks registration
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var authViewModel: AuthViewModel
    @State private var securityViewModel: SecurityViewModel
    @State private var recoveryViewModel: AccountRecoveryViewModel
    @State private var socialRecoveryService: SocialRecoveryService
    /// Bumped when `LocalDataWipe` swaps the store for an empty one. Everything under
    /// `ContentView` is rebuilt with it, because a `@FetchRequest` that outlives the swap keeps
    /// objects from the removed store, and the next fetch on the view context throws "persistent
    /// store is not reachable from this NSManagedObjectContext's coordinator" from inside its
    /// change observer. Build 712 crashed that way on the first message after deleting the
    /// account and registering again.
    @State private var storeGeneration = 0
    private let rootContainer: NSPersistentContainer

    init() {
        let isPreview = PreviewDetector.isRunningInPreview
        let container = isPreview
            ? PersistenceController.preview.container
            : PersistenceController.shared.container
        self.rootContainer = container
        _authViewModel = State(initialValue: AuthViewModel(context: container.viewContext, startRuntime: !isPreview))
        _securityViewModel = State(initialValue: SecurityViewModel())
        _recoveryViewModel = State(initialValue: AccountRecoveryViewModel())
        _socialRecoveryService = State(initialValue: SocialRecoveryService())
        // Eagerly load the CoreData stack so NSManagedObjectModel is registered
        // before any view body runs. On iOS 26 TabView / ZStack initialises
        // @FetchRequest for all children during the first layout pass; without
        // this the entity registry is empty and the app crashes with
        // 'A fetch request must have an entity.'
        applyGlobalAppearance()
        // Put RTCAudioSession into manual-audio mode and warm the WebRTC factory
        // BEFORE CallKit's first `didActivate` touches RTCAudioSession. Lazy-init
        // mid-call destructively reset `isAudioEnabled = false`, silencing every
        // call after that point.
        if !isPreview {
            MainActor.assumeIsolated {
                WebRTCRuntime.bootstrap()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            SecurityGateView {
                ContentView()
                    .environment(\.managedObjectContext, rootContainer.viewContext)
                    .environment(authViewModel)
                    .environment(appDelegate.deepLinkHandler)
                    .id(storeGeneration)
            }
            .onReceive(NotificationCenter.default.publisher(for: .localStoreReplaced).receive(on: DispatchQueue.main)) { _ in
                storeGeneration &+= 1
            }
            .environment(securityViewModel)
            .environment(authViewModel)   // PinLockView needs AuthViewModel for duress wipe
            .environment(recoveryViewModel)
            .environment(socialRecoveryService)
            .task {
                if PreviewDetector.isRunningInPreview {
                    return
                }
                RuntimeDiagnostics.shared.start()
                // DEBUG-only: records what the app was doing when the keyboard hid. Armed because
                // the composer-swap explanation for TODO 33 was fixed and the symptom stayed.
                KeyboardEventTracer.shared.start()
                MediaManager.shared.evictOldFiles()
                // Packs that ship in the app, into the store once. No network; first launch only.
                StickerService.shared.seedBundledPacks()
                StorageMigrationService.shared.migrateIfNeeded(
                    context: rootContainer.viewContext
                )
                // Start VEIL proxy if user has it enabled — async to allow .well-known cert fetch
                await VeilProxyManager.shared.startIfEnabled()
                // Kick the TransportRouter FSM into action. If the initial state demands ICE
                // (mode=.on or censored region), this triggers the first proxy probe.
                await TransportRouter.shared.bootstrap()
                // Post-auth key maintenance lives in AuthViewModel; this task can run before
                // async session restore completes.
            }
        }
    }

    // MARK: - Global UIKit appearance

    private func applyGlobalAppearance() {
        let accent  = UIColor(Color.CT.accent)
        let dim     = UIColor(Color.CT.textDim)
        let bright  = UIColor(Color.CT.text)
        let sep     = UIColor(Color.CT.noise)

        // ── Tab bar ──────────────────────────────────────────────────────────
        let tabApp = UITabBarAppearance()
        tabApp.configureWithTransparentBackground()
        tabApp.backgroundColor = .clear
        tabApp.backgroundEffect = nil
        tabApp.shadowColor = .clear
        tabApp.stackedLayoutAppearance.selected.iconColor = accent
        tabApp.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: accent]
        tabApp.stackedLayoutAppearance.normal.iconColor  = dim
        tabApp.stackedLayoutAppearance.normal.titleTextAttributes  = [.foregroundColor: dim]
        UITabBar.appearance().standardAppearance    = tabApp
        UITabBar.appearance().scrollEdgeAppearance  = tabApp

        // ── Navigation bar ───────────────────────────────────────────────────
        // The bar is the system's; ours is the title face, nothing else
        // (`decisions/navigation-bars-are-the-systems.md`). No `standardAppearance`: an
        // appearance of our own with a background turns the iOS 26 glass off. The title is the
        // chrome's monospace at 17 pt, on the headline curve. Bar items are the
        // label colour (`barItem()`), the accent only on a confirming action.
        let titleSize = UIFontMetrics(forTextStyle: .headline).scaledValue(for: 17)
        let titleFont = UIFont(name: "JetBrainsMono-SemiBold", size: titleSize)
            ?? .monospacedSystemFont(ofSize: titleSize, weight: .semibold)
        UINavigationBar.appearance().titleTextAttributes = [
            .foregroundColor: bright,
            .font: titleFont
        ]

        // ── Lists / Table views ──────────────────────────────────────────────
        UITableView.appearance().backgroundColor     = UIColor(Color.CT.bg)
        UITableView.appearance().separatorColor      = sep
        UITableViewCell.appearance().backgroundColor = .clear

        // ── Search bar ───────────────────────────────────────────────────────
        UISearchBar.appearance().barStyle   = .black
        UISearchBar.appearance().tintColor  = accent
        UITextField.appearance(
            whenContainedInInstancesOf: [UISearchBar.self]
        ).textColor = UIColor(Color.CT.text)
    }
}
#endif
