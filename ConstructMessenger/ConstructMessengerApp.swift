//
//  ConstructMessengerApp.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

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
            }
            .environment(securityViewModel)
            .environment(authViewModel)   // PinLockView needs AuthViewModel for duress wipe
            .environment(recoveryViewModel)
            .environment(socialRecoveryService)
            .task {
                if PreviewDetector.isRunningInPreview {
                    return
                }
                MediaManager.shared.evictOldFiles()
                StorageMigrationService.shared.migrateIfNeeded(
                    context: rootContainer.viewContext
                )
                // Start VEIL proxy if user has it enabled — async to allow .well-known cert fetch
                await VeilProxyManager.shared.startIfEnabled()
                // Kick the TransportRouter FSM into action. If the initial state demands ICE
                // (mode=.on or censored region), this triggers the first proxy probe.
                await TransportRouter.shared.bootstrap()
                // One-time migration: upload Kyber SPK for users registered before PQC launch.
                // Returns immediately if already done (UserDefaults flag). Remove in a future version.
                if authViewModel.isAuthenticated,
                   let deviceId = KeychainManager.shared.loadDeviceID() {
                    await PQCKeyManager.migrateIfNeeded(deviceId: deviceId)
                }
                // FIXME(masque): iOS blocks raw UDP port 443 (owned by Network.framework).
                // construct-engine's QUIC handshake times out immediately on iOS —
                // the engine event loop never starts and every dispatch is a no-op.
                // Re-enable once the MASQUE-over-TCP bridge is implemented.
                // do { try EngineAdapter.shared.start() } catch { ... }
            }
        }
    }

    // MARK: - Global UIKit appearance

    private func applyGlobalAppearance() {
        let bg2     = UIColor(Color.CT.bgMsg)
        let accent  = UIColor(Color.CT.accent)
        let dim     = UIColor(Color.CT.textDim)
        let bright  = UIColor(Color.CT.text)
        let sep     = UIColor(Color.CT.noise)

        // ── Tab bar ──────────────────────────────────────────────────────────
        let tabApp = UITabBarAppearance()
        tabApp.configureWithOpaqueBackground()
        tabApp.backgroundColor = UIColor(Color.CT.bg)
        tabApp.stackedLayoutAppearance.selected.iconColor = accent
        tabApp.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: accent]
        tabApp.stackedLayoutAppearance.normal.iconColor  = dim
        tabApp.stackedLayoutAppearance.normal.titleTextAttributes  = [.foregroundColor: dim]
        UITabBar.appearance().standardAppearance    = tabApp
        UITabBar.appearance().scrollEdgeAppearance  = tabApp

        // ── Navigation bar ───────────────────────────────────────────────────
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: bright,
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        ]
        let navApp = UINavigationBarAppearance()
        navApp.configureWithOpaqueBackground()
        navApp.backgroundColor              = bg2
        navApp.titleTextAttributes          = titleAttrs
        navApp.largeTitleTextAttributes     = [.foregroundColor: bright]
        navApp.shadowColor                  = UIColor(Color.CT.noise)
        UINavigationBar.appearance().standardAppearance   = navApp
        UINavigationBar.appearance().scrollEdgeAppearance = navApp
        UINavigationBar.appearance().compactAppearance    = navApp
        UINavigationBar.appearance().tintColor            = accent

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
