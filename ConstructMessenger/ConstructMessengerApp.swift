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

    @State private var authViewModel = AuthViewModel(context: PersistenceController.shared.container.viewContext)
    @State private var securityViewModel = SecurityViewModel()
    @State private var recoveryViewModel = AccountRecoveryViewModel()

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
}
