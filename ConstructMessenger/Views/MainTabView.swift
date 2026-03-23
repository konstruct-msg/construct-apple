//
//  MainTabView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI
import CoreData

struct MainTabView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel

    /// Compact = iPhone (or iPad in narrow split-screen multitasking)
    /// Regular = iPad full-screen or landscape
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            // iPad: sidebar + detail split layout
            ChatsSplitView()
                .environment(chatsViewModel)
        } else {
            // iPhone: classic tab bar navigation
            @Bindable var vm = chatsViewModel
            TabView(selection: $vm.selectedTab) {
                ChatsListView()
                    .environment(chatsViewModel)
                    .tabItem {
                        Label("chats", systemImage: "message")
                    }
                    .tag(0)

                SynapsView()
                    .environment(chatsViewModel)
                    .tabItem {
                        Label("synaps", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    }
                    .tag(1)

                #if os(iOS)
                SettingsView()
                    .tabItem {
                        Label("settings", systemImage: "gear")
                    }
                    .tag(2)
                #endif
            }
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
        .environment(authViewModel)
        .environment(chatsViewModel)
        .environment(SecurityViewModel())
}
#endif
