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
    
    @State private var isCheckingAuth = true
    @State private var hasDeviceKeys = false

    var body: some View {
        Group {
            if isCheckingAuth {
                // Loading screen while checking Keychain
                ProgressView("Loading...")
            } else if hasDeviceKeys {
                // Device is registered - show main app
                // (Session token will be obtained via device-based auth)
                MainTabView()
                    .environmentObject(authViewModel)
                    .environmentObject(chatsViewModel)
            } else {
                // No device keys = new user -> show onboarding
                OnboardingView()
                    .onDisappear {
                        // Re-check device keys when onboarding dismisses
                        checkDeviceKeys()
                    }
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
        .onAppear {
            // Check for device keys first
            checkDeviceKeys()
            
            // ✅ Session is now restored in AuthViewModel.init()
            // Just set the context for ChatsViewModel
            chatsViewModel.setContext(viewContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DeviceKeysDeleted"))) { _ in
            Log.info("📢 Received 'DeviceKeysDeleted' notification", category: "ContentView")
            checkDeviceKeys()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DeviceRegistered"))) { _ in
            Log.info("📢 Received 'DeviceRegistered' notification", category: "ContentView")
            checkDeviceKeys()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Always restore connection when coming from background to foreground
                print("📱 App became active, attempting to restore connection...")
                authViewModel.restoreSession()
            } else if newPhase == .background {
                print("⏹️ App went to background.")
                // gRPC architecture - stream disconnected gracefully
                // Long polling will resume when app becomes active
            }
        }
        .onChange(of: deepLinkHandler.deepLink) { _, newDeepLink in
            Log.debug("ContentView: Deep link changed: \(String(describing: newDeepLink))", category: "DeepLink")
            if case .contact(let contactInfo) = newDeepLink {
                Log.info("ContentView: Creating chat directly for userId: \(contactInfo.userId), username: \(contactInfo.username)", category: "DeepLink")
                
                // ✅ Create chat directly instead of opening modal
                let publicUserInfo = PublicUserInfo(
                    id: contactInfo.userId,
                    username: contactInfo.username,
                    avatarUrl: nil,
                    bio: nil,
                    deviceId: contactInfo.deviceId
                )
                
                if let chat = chatsViewModel.startChat(with: publicUserInfo) {
                    Log.info("ContentView: Chat created successfully, opening chat with id: \(chat.id)", category: "DeepLink")
                    chatsViewModel.chatToOpen = chat.id
                } else {
                    Log.error("ContentView: Failed to create chat for userId: \(contactInfo.userId)", category: "DeepLink")
                }
                
                // Clear the deep link
                deepLinkHandler.deepLink = nil
            }
        }
        .onOpenURL { url in
            // ✅ Handle Universal Links in SwiftUI (iOS 13+)
            Log.info("ContentView: Received URL via onOpenURL: \(url.absoluteString)", category: "DeepLink")
            let result = deepLinkHandler.handleURL(url)
            Log.info("ContentView: Deep link handling result: \(result)", category: "DeepLink")
        }
    }
    
    private func checkDeviceKeys() {
        Log.info("🔍 Checking device keys in Keychain...", category: "ContentView")
        
        // Check if device keys exist in Keychain
        let wasRegistered = hasDeviceKeys
        hasDeviceKeys = KeychainManager.shared.isDeviceRegistered()
        isCheckingAuth = false
        
        if hasDeviceKeys != wasRegistered {
            Log.info("   📱 Device registration status CHANGED: \(wasRegistered) → \(hasDeviceKeys)", category: "ContentView")
        }
        
        if hasDeviceKeys {
            Log.info("   ✅ Device is registered - showing main app", category: "ContentView")
        } else {
            Log.info("   ❌ Device NOT registered - showing onboarding", category: "ContentView")
        }
    }
}

#if DEBUG
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
#endif

#if DEBUG
#Preview("Authenticated") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    
    guard context.persistentStoreCoordinator != nil else {
        fatalError("Preview Core Data context not ready")
    }
    
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth(username: "john_doe", displayName: "John Doe")
    let deepLinkHandler = DeepLinkHandler()
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)

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
        .environmentObject(chatsViewModel)
}
#endif
