//
//  MainTabView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI
import CoreData

struct MainTabView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @EnvironmentObject var chatsViewModel: ChatsViewModel

    /// Compact = iPhone (or iPad in narrow split-screen multitasking)
    /// Regular = iPad full-screen or landscape
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad: sidebar + detail split layout
            ChatsSplitView()
                .environmentObject(chatsViewModel)
        } else {
            // iPhone: classic tab bar navigation
            TabView {
                ChatsListView()
                    .environmentObject(chatsViewModel)
                    .tabItem {
                        Label("chats", systemImage: "bubble.left.and.bubble.right")
                    }

                SettingsView()
                    .tabItem {
                        Label("settings", systemImage: "slider.horizontal.3")
                    }
            }
            .tint(Color.AppBrand.second)
        }
    }
}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    
    guard context.persistentStoreCoordinator != nil else {
        fatalError("Preview Core Data context not ready")
    }
    
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()
    
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)

    // Create sample chats
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)
    try? context.save()

    return MainTabView()
        .environment(\.managedObjectContext, context)
        .environmentObject(authViewModel)
        .environmentObject(chatsViewModel)
        .environmentObject(SecurityViewModel())
}
#endif
