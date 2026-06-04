//
//  ChatsSplitView.swift
//  Construct Messenger
//
//  iPad split-view layout: sidebar (chat list) + detail (open chat).
//  Used automatically on regular-width size class (iPad, or iPhone landscape
//  on Pro Max when split-view multitasking is active).
//
//  iPhone (compact) keeps the existing TabView + NavigationStack layout
//  in MainTabView — this file is only instantiated for regular width.
//

import SwiftUI
import CoreData

struct ChatsSplitView: View {
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Chat.isPinned, ascending: false),
            NSSortDescriptor(keyPath: \Chat.lastMessageTime, ascending: false)
        ],
        animation: .default
    )
    private var chats: FetchedResults<Chat>

    @State private var selectedChatId: String?
    @State private var showingQRScanner = false
    @State private var activeTab: SidebarTab = .chats
    @State private var showingDrafts = false

    private enum SidebarTab { case chats, settings }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarChats
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if !targetEnvironment(macCatalyst)
                Divider()
                sidebarTabBar
                #endif
            }
            .navigationTitle("chats")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingQRScanner = true
                    } label: {
                        Text("[qr]")
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.accent)
                            .lineLimit(1).fixedSize()
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingQRScanner = true
                    } label: {
                        Text("[qr]")
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.accent)
                            .lineLimit(1).fixedSize()
                    }
                }
                #endif
                ToolbarItem(placement: .principal) {
                    ConnectionStatusIndicator()
                }
                #if targetEnvironment(macCatalyst)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if activeTab == .settings {
                            activeTab = .chats
                        } else {
                            activeTab = .settings
                            selectedChatId = nil
                        }
                    } label: {
                        Text(activeTab == .settings ? "[msg]" : "[⚙]")
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.accent)
                            .lineLimit(1).fixedSize()
                    }
                }
                #endif
            }
            .sheet(isPresented: $showingQRScanner) {
                QRScannerView { contactURL in
                    handleScannedContact(contactURL)
                }
            }
            .sheet(isPresented: $showingDrafts) {
                DraftsView()
            }
        } detail: {
            detailContent
        }
        .onAppear {
            chatsViewModel.setContext(viewContext)
        }
        .onChange(of: chatsViewModel.chatToOpen) { _, chatId in
            if let chatId {
                selectedChatId = chatId
                activeTab = .chats
                chatsViewModel.chatToOpen = nil
            }
        }
        .onChange(of: selectedChatId) { _, newId in
            if newId != nil {
                activeTab = .chats
            }
        }
    }

    // MARK: - Sidebar: Tab Bar

    private var sidebarTabBar: some View {
        HStack(spacing: 0) {
            sidebarTabButton(
                title: "chats",
                systemImage: "message",
                tab: .chats
            )
            sidebarTabButton(
                title: "settings",
                systemImage: "gear",
                tab: .settings
            )
        }
        .frame(height: 56)
        .background(.bar)
    }

    @ViewBuilder
    private func sidebarTabButton(title: LocalizedStringKey, systemImage: String, tab: SidebarTab) -> some View {
        let selected = activeTab == tab
        let ascii = systemImage == "message" ? "[msg]" : "[⚙]"
        Button {
            activeTab = tab
            if tab == .chats {
                selectedChatId = selectedChatId
            } else {
                selectedChatId = nil
            }
        } label: {
            VStack(spacing: 3) {
                Text(ascii)
                    .font(CTFont.bold(selected ? 16 : 14))
                    .lineLimit(1).fixedSize()
                Text(title)
                    .font(CTFont.regular(10))
            }
            .foregroundStyle(selected ? Color.CT.accent : Color.CT.textDim)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sidebar: Chats

    private var sidebarChats: some View {
        List(selection: $selectedChatId) {
            ForEach(chats) { chat in
                ChatRowView(chat: chat)
                    .tag(chat.id)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteChat(chat) } label: {
                            Label(LocalizedStringKey("delete"), systemImage: "trash")
                        }
                        Button { toggleMarkUnread(chat) } label: {
                            Label(LocalizedStringKey(chat.unreadCount > 0 ? "mark_read" : "mark_unread"),
                                  systemImage: chat.unreadCount > 0 ? "envelope.open" : "envelope.badge")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { togglePin(chat) } label: {
                            Label(LocalizedStringKey(chat.isPinned ? "unpin" : "pin"),
                                  systemImage: chat.isPinned ? "pin.slash" : "pin")
                        }
                        .tint(.yellow)
                    }
                    .contextMenu {
                        Button(role: .destructive) { deleteChat(chat) } label: {
                            Label("delete_chat", systemImage: "trash")
                        }
                    }
            }
            .onDelete(perform: deleteChatsAtOffsets)
        }
        .refreshable {
            #if os(iOS)
            await BackgroundFetchManager.shared.fetchPendingMessages()
            #endif
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if activeTab == .settings && selectedChatId == nil {
            #if os(iOS)
            SettingsView()
            #else
            DesktopSettingsView()
            #endif
        } else if let chatId = selectedChatId,
           let chat = chats.first(where: { $0.id == chatId }) {
            ChatView(chat: chat, context: viewContext)
        } else {
            ContentUnavailableView(
                String(localized: "select_chat"),
                systemImage: "message",
                description: Text("select_chat_description")
            )
        }
    }

    // MARK: - Actions

    private func deleteChat(_ chat: Chat) {
        if selectedChatId == chat.id {
            selectedChatId = nil
        }
        Task { await chatsViewModel.deleteChatWithEndSession(chat: chat) }
    }

    private func deleteChatsAtOffsets(at offsets: IndexSet) {
        offsets.map { chats[$0] }.forEach { deleteChat($0) }
    }

    private func togglePin(_ chat: Chat) {
        chat.isPinned.toggle()
        try? viewContext.save()
    }

    private func toggleMarkUnread(_ chat: Chat) {
        chat.unreadCount = chat.unreadCount > 0 ? 0 : 1
        try? viewContext.save()
    }

    private func handleScannedContact(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            showErrorAfterDismiss(NSLocalizedString("invalid_qr_code_construct", comment: ""))
            return
        }
        Task {
            do {
                let contactInfo = try await LinkParser.parseContactLink(url)
                await MainActor.run {
                    addContact(contactInfo: contactInfo)
                    showingQRScanner = false
                }
            } catch {
                await MainActor.run {
                    showErrorAfterDismiss(error.localizedDescription)
                    showingQRScanner = false
                }
            }
        }
    }

    private func addContact(contactInfo: ContactInfo) {
        if contactInfo.userId == AuthSessionManager.shared.currentUserId {
            showingDrafts = true
            return
        }
        let publicUserInfo = PublicUserInfo(
            id: contactInfo.userId,
            username: contactInfo.username,
            avatarUrl: nil,
            bio: nil,
            deviceId: contactInfo.deviceId
        )
        if let chat = chatsViewModel.startChat(with: publicUserInfo) {
            selectedChatId = chat.id
        }
    }

    private func showErrorAfterDismiss(_ message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            ErrorRouter.shared.report(.unknown(message))
        }
    }
}
