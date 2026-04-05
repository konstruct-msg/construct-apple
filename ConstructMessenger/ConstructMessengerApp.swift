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

    @State private var authViewModel = AuthViewModel(context: PersistenceController.shared.container.viewContext)
    @State private var securityViewModel = SecurityViewModel()
    @State private var recoveryViewModel = AccountRecoveryViewModel()

    init() {
        // Eagerly load the CoreData stack so NSManagedObjectModel is registered
        // before any view body runs. On iOS 26 TabView initialises @FetchRequest
        // for all tabs during the first layout pass; without this the entity
        // registry is empty and the app crashes with "A fetch request must have an entity."
        _ = PersistenceController.shared
        applyGlobalAppearance()
    }

    var body: some Scene {
        WindowGroup {
            SecurityGateView {
                ContentView()
                    .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                    .environment(authViewModel)
                    .environment(appDelegate.deepLinkHandler)
            }
            .environment(securityViewModel)
            .environment(authViewModel)   // PinLockView needs AuthViewModel for duress wipe
            .environment(recoveryViewModel)
            .task {
                MediaManager.shared.evictOldFiles()
                // Start ICE proxy if user has it enabled — async to allow .well-known cert fetch
                await IceProxyManager.shared.startIfEnabled()
                // One-time migration: upload Kyber SPK for users registered before PQC launch.
                // Returns immediately if already done (UserDefaults flag). Remove in a future version.
                if authViewModel.isAuthenticated,
                   let deviceId = KeychainManager.shared.loadDeviceID() {
                    await PQCKeyManager.migrateIfNeeded(deviceId: deviceId)
                }
            }
        }
    }

    // MARK: - Global UIKit appearance

    private func applyGlobalAppearance() {
        let bg2     = UIColor(Color.Construct.bg2)
        let accent  = UIColor(Color.Construct.accent)
        let dim     = UIColor(Color.Construct.textDim)
        let bright  = UIColor(Color.Construct.textBright)
        let sep     = UIColor(Color.Construct.dim)

        // ── Tab bar ──────────────────────────────────────────────────────────
        let tabApp = UITabBarAppearance()
        tabApp.configureWithOpaqueBackground()
        tabApp.backgroundColor = UIColor(Color.Construct.bg)
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
        navApp.shadowColor                  = UIColor(Color.Construct.line)
        UINavigationBar.appearance().standardAppearance   = navApp
        UINavigationBar.appearance().scrollEdgeAppearance = navApp
        UINavigationBar.appearance().compactAppearance    = navApp
        UINavigationBar.appearance().tintColor            = accent

        // ── Lists / Table views ──────────────────────────────────────────────
        UITableView.appearance().backgroundColor     = UIColor(Color.Construct.bg)
        UITableView.appearance().separatorColor      = sep
        UITableViewCell.appearance().backgroundColor = .clear

        // ── Search bar ───────────────────────────────────────────────────────
        UISearchBar.appearance().barStyle   = .black
        UISearchBar.appearance().tintColor  = accent
        UITextField.appearance(
            whenContainedInInstancesOf: [UISearchBar.self]
        ).textColor = UIColor(Color.Construct.text)
    }
}
