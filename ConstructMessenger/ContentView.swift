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
    @EnvironmentObject var deepLinkHandler: DeepLinkHandler // Inject DeepLinkHandler
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    @StateObject private var chatsViewModel = ChatsViewModel()
    @State private var showingNewChatSheet = false
    @State private var contactInfoFromDeepLink: ContactInfo?

    var body: some View {
        Group {
            if authViewModel.isAuthenticated {
                MainTabView()
                    .environmentObject(chatsViewModel)
                    .sheet(isPresented: $showingNewChatSheet, onDismiss: {
                        // Clear the deep link after the sheet is dismissed
                        deepLinkHandler.deepLink = nil
                    }) {
                        if let contactInfo = contactInfoFromDeepLink {
                            // ✅ Use existing chatsViewModel from ContentView
                            NewChatView(chatsViewModel: chatsViewModel, initialContactInfo: contactInfo)
                                .environment(\.managedObjectContext, viewContext)
                        }
                    }
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
        .onChange(of: deepLinkHandler.deepLink) { newDeepLink in
            Log.debug("ContentView: Deep link changed: \(String(describing: newDeepLink))", category: "DeepLink")
            if case .contact(let contactInfo) = newDeepLink {
                Log.info("ContentView: Opening new chat sheet for userId: \(contactInfo.userId), username: \(contactInfo.username)", category: "DeepLink")
                contactInfoFromDeepLink = contactInfo
                showingNewChatSheet = true
            }
        }
        .onOpenURL { url in
            // ✅ Handle Universal Links in SwiftUI (iOS 13+)
            Log.info("ContentView: Received URL via onOpenURL: \(url.absoluteString)", category: "DeepLink")
            let result = deepLinkHandler.handleURL(url)
            Log.info("ContentView: Deep link handling result: \(result)", category: "DeepLink")
        }
    }
}

#Preview("Not Authenticated") {
    let container = PreviewHelpers.createPreviewContainer()
    let authViewModel = AuthViewModel(context: container.viewContext)
    authViewModel.isAuthenticated = false
    let deepLinkHandler = DeepLinkHandler()

    return ContentView()
        .environment(\.managedObjectContext, container.viewContext)
        .environmentObject(authViewModel)
        .environmentObject(deepLinkHandler)
}

#Preview("Authenticated") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let authViewModel = AuthViewModel(context: context)
    authViewModel.isAuthenticated = true
    authViewModel.currentUserId = "me"
    authViewModel.currentUsername = "john_doe"
    authViewModel.currentDisplayName = "John Doe"
    let deepLinkHandler = DeepLinkHandler()

    // Create sample chats
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)
    try? context.save()

    return ContentView()
        .environment(\.managedObjectContext, context)
        .environmentObject(authViewModel)
        .environmentObject(deepLinkHandler)
}
