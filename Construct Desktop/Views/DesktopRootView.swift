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
    static let desktopSelectNextChat = Notification.Name("desktopSelectNextChat")
    static let desktopSelectPrevChat = Notification.Name("desktopSelectPrevChat")
    static let desktopJumpToChat     = Notification.Name("desktopJumpToChat")
}

struct DesktopRootView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(DeepLinkHandler.self) private var deepLinkHandler
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.commandBridge) private var commandBridge
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showAddContact = false
    @State private var sidebarMode: SidebarMode = .chats

    private enum SidebarMode { case chats, synaps }

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
            wireCommandBridge()
        }
        .onReceive(NotificationCenter.default.publisher(for: .desktopShowAddContact)) { _ in
            showAddContact = true
        }
        .onChange(of: chatsViewModel.totalUnreadCount) { _, count in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }

    // Wire keyboard commands → ViewModels

    private func wireCommandBridge() {
        commandBridge.onNewConversation = { chatsViewModel.showNewChat = true }
        commandBridge.onAddContact      = { showAddContact = true }
        commandBridge.onFocusSearch     = { chatsViewModel.sidebarSearchFocused = true }
        commandBridge.onGlobalSearch    = { chatsViewModel.sidebarSearchFocused = true }
        commandBridge.onSelectNext      = {
            NotificationCenter.default.post(name: .desktopSelectNextChat, object: nil)
        }
        commandBridge.onSelectPrev      = {
            NotificationCenter.default.post(name: .desktopSelectPrevChat, object: nil)
        }
        commandBridge.onJumpToIndex     = { idx in
            NotificationCenter.default.post(name: .desktopJumpToChat, object: idx)
        }
        commandBridge.onBack            = { chatsViewModel.chatToOpen = nil }
        commandBridge.onCopyNodeId      = {
            guard let id = chatsViewModel.chatToOpen else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
        }
    }

    // MARK: - Main split view (authenticated)

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: mode toggle + either chats list or synaps grid
            VStack(spacing: 0) {
                sidebarModeBar
                Rectangle().fill(Color.CT.noise).frame(height: 1)

                if sidebarMode == .chats {
                    ChatsListView()
                        .environment(chatsViewModel)
                } else {
                    DesktopSynapsView()
                        .environment(chatsViewModel)
                        .environment(\.managedObjectContext, viewContext)
                }
            }
            .background(Color.CT.bg)
            .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 360)
        } detail: {
            // Detail: active chat or placeholder
            if let chatId = chatsViewModel.chatToOpen,
               let chat = fetchChat(id: chatId) {
                ChatView(chat: chat, context: viewContext)
                    .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                        handleDrop(providers: providers, into: chat)
                    }
            } else {
                DesktopEmptyStateView()
                    .onDrop(of: [.fileURL], isTargeted: nil) { _ in false }
            }
        }
        .frame(minWidth: 700, minHeight: 480)
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
        // Toolbar — CT ASCII style
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 2) {
                    modeButton("CHATS", mode: .chats)
                    Text("·")
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.noise)
                    modeButton("SYNAPS", mode: .synaps)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddContact = true
                } label: {
                    Text("[QR]")
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }
                .help("Scan QR code to add contact")
            }
        }
    }

    // MARK: - Sidebar mode toggle bar

    private var sidebarModeBar: some View {
        HStack(spacing: 0) {
            sidebarTab(label: "CHATS", mode: .chats)
            Rectangle().fill(Color.CT.noise).frame(width: 1)
            sidebarTab(label: "SYNAPS", mode: .synaps)

            Spacer()

            // Contextual action: [+] in Synaps mode, [+] new chat in Chats mode
            Button {
                if sidebarMode == .synaps {
                    NotificationCenter.default.post(name: .desktopShowAddContact, object: nil)
                } else {
                    chatsViewModel.showNewChat = true
                }
            } label: {
                Text("[+]")
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.accent)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .help(sidebarMode == .synaps ? "Add contact" : "New conversation (⌘N)")
        }
        .frame(height: 34)
        .background(Color.CT.bg)
    }

    private func sidebarTab(label: String, mode: SidebarMode) -> some View {
        let isActive = sidebarMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { sidebarMode = mode }
        } label: {
            VStack(spacing: 0) {
                Text(label)
                    .font(CTFont.bold(10))
                    .tracking(3)
                    .foregroundStyle(isActive ? Color.CT.accent : Color.CT.textDim)
                    .frame(maxWidth: .infinity)
                    .frame(height: 33)
                // Active underline
                Rectangle()
                    .fill(isActive ? Color.CT.accent : Color.clear)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private func modeButton(_ label: String, mode: SidebarMode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { sidebarMode = mode }
        } label: {
            Text("[\(label)]")
                .font(CTFont.regular(11))
                .foregroundStyle(sidebarMode == mode ? Color.CT.accent : Color.CT.textDim)
        }
        .buttonStyle(.plain)
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