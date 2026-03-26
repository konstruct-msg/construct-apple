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

extension Notification.Name {
    static let desktopShowAddContact = Notification.Name("desktopShowAddContact")
}

struct DesktopRootView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(DeepLinkHandler.self) private var deepLinkHandler
    @Environment(\.managedObjectContext) private var viewContext
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    // Sidebar column visibility (user can hide sidebar with toggle)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showAddContact = false

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
        .onReceive(NotificationCenter.default.publisher(for: .desktopShowAddContact)) { _ in
            showAddContact = true
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
                DesktopEmptyStateView()
                    .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        // Add Contact sheet (⌘⌥N)
        .sheet(isPresented: $showAddContact) {
            DesktopAddContactView()
                .environment(authViewModel)
                .environment(deepLinkHandler)
        }
        // New Chat sheet (⌘N)
        .sheet(isPresented: Binding(
            get: { chatsViewModel.showNewChat },
            set: { chatsViewModel.showNewChat = $0 }
        )) {
            NewChatView(chatsViewModel: chatsViewModel)
                .environment(\.managedObjectContext, viewContext)
                .frame(minWidth: 400, minHeight: 300)
        }
        // Toolbar button — sidebar header
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showAddContact = true
                } label: {
                    Label("Add Contact", systemImage: "person.badge.plus")
                }
                .help("Add Contact (⌥⌘N)")
                .keyboardShortcut("n", modifiers: [.command, .option])
            }
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

// MARK: - Xcode Previews

#Preview("Empty state (no chat selected)") {
    // Shows the detail pane when no conversation is open — quick layout check
    // without needing to launch the full app.
    DesktopEmptyStateView()
        .frame(width: 760, height: 500)
}

#Preview("Add Contact sheet") {
    DesktopAddContactView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(DeepLinkHandler())
}