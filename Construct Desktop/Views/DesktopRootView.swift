//
//  DesktopRootView.swift
//  Construct Desktop
//
//  Root view for the macOS app.
//  Mirrors ContentView.swift (iOS) — routes between onboarding and main UI
//  based on AuthViewModel.hasRegisteredDeviceKeys.
//

import SwiftUI
import CoreData

struct DesktopRootView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    var body: some View {
        Group {
            if authViewModel.hasRegisteredDeviceKeys == nil {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authViewModel.hasRegisteredDeviceKeys == true {
                mainContent
            } else {
                OnboardingView()
                    .environment(authViewModel)
                    .onDisappear {
                        authViewModel.refreshDeviceKeyState()
                    }
            }
        }
        .preferredColorScheme(appTheme.colorScheme)
        .onAppear {
            authViewModel.refreshDeviceKeyState()
        }
    }

    // MARK: - Main split view (authenticated)

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // Sidebar: chats list
            ChatsListView()
                .environment(chatsViewModel)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            // Detail: active chat or placeholder
            if let chatId = chatsViewModel.chatToOpen,
               let chat = fetchChat(id: chatId) {
                ChatView(chat: chat, context: viewContext)
            } else {
                DesktopEmptyDetailView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    private func fetchChat(id: String) -> Chat? {
        let req = Chat.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", id)
        req.fetchLimit = 1
        return try? viewContext.fetch(req).first
    }
}

// MARK: - Empty detail state

private struct DesktopEmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Select a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("or scan a QR code with ⌘N")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

