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
import AppKit
import UniformTypeIdentifiers

struct DesktopRootView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    // Sidebar column visibility (user can hide sidebar with toggle)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
        // Update Dock badge with unread count
        .onChange(of: chatsViewModel.totalUnreadCount) { _, count in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    // MARK: - Main split view (authenticated)

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: chats list with search
            ChatsListView()
                .environment(chatsViewModel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            // Detail: active chat or placeholder
            if let chatId = chatsViewModel.chatToOpen,
               let chat = fetchChat(id: chatId) {
                ChatView(chat: chat, context: viewContext)
                    // Accept dropped images/files directly into the chat
                    .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                        handleDrop(providers: providers, into: chat)
                    }
            } else {
                DesktopEmptyDetailView()
                    .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        // New Chat sheet (⌘N)
        .sheet(isPresented: Binding(
            get: { chatsViewModel.showNewChat },
            set: { chatsViewModel.showNewChat = $0 }
        )) {
            NewChatView(chatsViewModel: chatsViewModel)
                .environment(\.managedObjectContext, viewContext)
                .frame(minWidth: 400, minHeight: 300)
        }
    }

    // MARK: - Drag & Drop into chat

    private func handleDrop(providers: [NSItemProvider], into chat: Chat) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data, let image = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        // Push dropped image to ChatView via ChatsViewModel
                        chatsViewModel.pendingDroppedImage = image
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        chatsViewModel.pendingDroppedFileURL = url
                    }
                }
                handled = true
            }
        }
        return handled
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
            Text("Press ⌘N to start a new chat")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


