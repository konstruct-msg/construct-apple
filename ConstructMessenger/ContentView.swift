//
//  ContentView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

struct ContentView: View {
    @Environment(AuthViewModel.self) var authViewModel
    @Environment(DeepLinkHandler.self) var deepLinkHandler
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage("appTheme") private var appTheme: AppTheme = .dark

    @State private var chatsViewModel = ChatsViewModel()

    var body: some View {
        Group {
            if authViewModel.hasRegisteredDeviceKeys == nil {
                // Auth state not yet resolved — show splash while Keychain is read.
                // This happens on cold launch AND when coming to foreground with a locked
                // device (SecurityGateView sits in ZStack so onAppear fires immediately).
                SplashView()
            } else if authViewModel.deviceKeysUnavailable {
                // Authenticated but crypto keys couldn't be loaded — show recovery screen.
                // Keys are NOT wiped; user can retry, recover via seed phrase, or register new.
                KeysRecoveryView()
                    .environment(authViewModel)
            } else if authViewModel.isAuthenticated || authViewModel.hasRegisteredDeviceKeys == true {
                // Authenticated OR definitively registered — show main app.
                // Checking isAuthenticated here prevents a flash to OnboardingView when
                // Keychain is temporarily unavailable (WhenUnlockedThisDeviceOnly) but
                // the user's session is still valid in memory.
                MainTabView()
                    .environment(authViewModel)
                    .environment(chatsViewModel)
            } else {
                // No device keys and not authenticated → new user or wiped account.
                OnboardingView()
                    .onDisappear {
                        authViewModel.refreshDeviceKeyState()
                    }
            }
        }
        .errorToast()
        .preferredColorScheme(appTheme.colorScheme)
        .onAppear {
            authViewModel.refreshDeviceKeyState()
            chatsViewModel.setContext(viewContext)
            handleDeepLink(deepLinkHandler.deepLink)
        }
        .onReceive(NotificationCenter.default.publisher(for: .appWillEnterForeground)) { _ in
            // Fires only when returning from true background — not for brief interruptions
            // (Control Center, alerts, biometrics). scenePhase == .active would fire for all of those.
            //
            // Also retry if the crypto core was never initialized — happens when the app was
            // woken in background while the device was locked (WhenUnlockedThisDeviceOnly keys
            // temporarily unavailable). Now that the user is bringing the app to foreground,
            // the device is unlocked and Keychain items are accessible.
            if AuthSessionManager.shared.sessionToken == nil || !AuthSessionManager.shared.isSessionValid
                || !CryptoManager.shared.isInitialized {
                Log.info("App returning to foreground — restoring session (token missing, expired, or crypto uninitialised)", category: "Auth")
                authViewModel.restoreSession()
            }

            // If stealth is on and wallet is low, ensure we have an initial/top-up batch.
            if AuthSessionManager.shared.isSessionValid,
               StealthPolicy.shared.isEnabled,
               TokenWalletService.shared.balance < 10 {
                Task {
                    await BlindTokenService.shared.bootstrapInitialBatch()
                }
            }
        }
        .onChange(of: deepLinkHandler.deepLink) { _, newDeepLink in
            handleDeepLink(newDeepLink)
        }
        .onOpenURL { url in
            // Handle Universal Links in SwiftUI (iOS 13+)
            Log.info("ContentView: Received URL via onOpenURL: \(url.absoluteString)", category: "DeepLink")
            let result = deepLinkHandler.handleURL(url)
            Log.info("ContentView: Deep link handling result: \(result)", category: "DeepLink")
        }
    }

    private func handleDeepLink(_ deepLink: DeepLinkType?) {
        Log.debug("ContentView: Deep link changed: \(String(describing: deepLink))", category: "DeepLink")
        if case .contact(let contactInfo) = deepLink {
            Log.info("ContentView: Creating chat directly for userId: \(contactInfo.userId), username: \(contactInfo.username)", category: "DeepLink")

            // Create chat directly instead of opening modal
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

            deepLinkHandler.deepLink = nil
        } else if case .openChat(let chatId) = deepLink {
            Log.info("ContentView: Opening chat from push notification: \(chatId)", category: "DeepLink")
            chatsViewModel.chatToOpen = chatId
            deepLinkHandler.deepLink = nil
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
        .environment(authViewModel)
        .environment(deepLinkHandler)
        .environment(AccountRecoveryViewModel())
        .environment(SocialRecoveryService())
        .environment(SecurityViewModel())
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
        .environment(authViewModel)
        .environment(deepLinkHandler)
        .environment(chatsViewModel)
        .environment(AccountRecoveryViewModel())
        .environment(SocialRecoveryService())
        .environment(SecurityViewModel())
}
#endif
