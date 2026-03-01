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
    @EnvironmentObject var chatsViewModel: ChatsViewModel
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Chat.lastMessageTime, ascending: false)],
        animation: .default
    )
    private var chats: FetchedResults<Chat>

    @State private var selectedChatId: String?
    @State private var showingQRScanner = false
    @State private var sidebarContent: SidebarTab = .chats
    @State private var showingDrafts = false
    @State private var showingError = false
    @State private var errorMessage = ""

    private enum SidebarTab { case chats, settings }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Group {
                    if sidebarContent == .chats {
                        sidebarChats
                    } else {
                        SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                sidebarTabBar
            }
            .navigationTitle(sidebarContent == .chats ? "chats" : "settings")
            .toolbar {
                if sidebarContent == .chats {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingQRScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder")
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        ConnectionStatusIndicator()
                    }
                }
            }
            .sheet(isPresented: $showingQRScanner) {
                QRScannerView { contactURL in
                    handleScannedContact(contactURL)
                }
            }
            .sheet(isPresented: $showingDrafts) {
                DraftsView()
            }
            .alert("error", isPresented: $showingError) {
                Button("ok") {}
            } message: {
                Text(errorMessage)
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
                chatsViewModel.chatToOpen = nil
            }
        }
    }

    // MARK: - Sidebar: Tab Bar

    private var sidebarTabBar: some View {
        HStack(spacing: 0) {
            sidebarTabButton(
                title: "chats",
                systemImage: "bubble.left.and.bubble.right",
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
        let selected = sidebarContent == tab
        Button {
            sidebarContent = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sidebar: Chats

    private var sidebarChats: some View {
        List(selection: $selectedChatId) {
            ForEach(chats) { chat in
                ChatRowView(chat: chat)
                    .tag(chat.id ?? "")
            }
            .onDelete(perform: deleteChats)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let chatId = selectedChatId,
           let chat = chats.first(where: { $0.id == chatId }) {
            ChatView(chat: chat, context: viewContext)
        } else {
            ContentUnavailableView(
                String(localized: "select_chat"),
                systemImage: "bubble.left.and.bubble.right",
                description: Text("select_chat_description")
            )
        }
    }

    // MARK: - Actions

    private func deleteChats(at offsets: IndexSet) {
        for index in offsets {
            let chat = chats[index]
            if selectedChatId == chat.id {
                selectedChatId = nil
            }
            viewContext.delete(chat)
        }
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
        if contactInfo.userId == SessionManager.shared.currentUserId {
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
        errorMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showingError = true
        }
    }
}
