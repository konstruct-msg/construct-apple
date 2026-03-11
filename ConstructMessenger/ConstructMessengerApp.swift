//
//  ConstructMessengerApp.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

@main
struct Construct_MessengerApp: App {
    // IMPORTANT: AppDelegate for background tasks registration
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    static let persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ConstructMessenger")

        // Enable automatic lightweight migration for Core Data model changes
        if let description = container.persistentStoreDescriptions.first {
            description.shouldInferMappingModelAutomatically = true
            description.shouldMigrateStoreAutomatically = true
        }

        // Load persistent stores asynchronously to avoid blocking app launch.
        container.loadPersistentStores { _, error in
            if let error = error {
                print("❌ Failed to load persistent stores: \(error)")
            } else {
                print("✅ Persistent stores loaded successfully")
            }
        }

        return container
    }()

    @State private var authViewModel = AuthViewModel(context: Construct_MessengerApp.persistentContainer.viewContext)
    @State private var securityViewModel = SecurityViewModel()
    @State private var recoveryViewModel = AccountRecoveryViewModel()

    var body: some Scene {
        WindowGroup {
            SecurityGateView {
                ContentView()
                    .environment(\.managedObjectContext, Construct_MessengerApp.persistentContainer.viewContext)
                    .environment(authViewModel)
                    .environment(appDelegate.deepLinkHandler)
            }
            .environment(securityViewModel)
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
}
