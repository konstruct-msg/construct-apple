//
//  ContentView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    var body: some View {
        Group {
            if authViewModel.isAuthenticated {
                MainTabView()
            } else {
                AuthView()
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
        .onAppear {
            // This will run once when ContentView first appears
            authViewModel.restoreSession()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                // Always restore connection when coming from background to foreground
                print("📱 App became active, attempting to restore connection...")
                authViewModel.restoreSession()
            } else if newPhase == .background {
                print("⏹️ App went to background. Disconnecting WebSocket.")
                // Disconnect when going to background to save resources
                // The connection will be restored when app becomes active again
                WebSocketManager.shared.disconnect()
            }
        }
    }
}

#Preview("Not Authenticated") {
    let container = PreviewHelpers.createPreviewContainer()
    let authViewModel = AuthViewModel(context: container.viewContext)
    authViewModel.isAuthenticated = false

    return ContentView()
        .environment(\.managedObjectContext, container.viewContext)
        .environmentObject(authViewModel)
}

#Preview("Authenticated") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let authViewModel = AuthViewModel(context: context)
    authViewModel.isAuthenticated = true
    authViewModel.currentUserId = "me"
    authViewModel.currentUsername = "john_doe"
    authViewModel.currentDisplayName = "John Doe"

    // Create sample chats
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)
    try? context.save()

    return ContentView()
        .environment(\.managedObjectContext, context)
        .environmentObject(authViewModel)
}
