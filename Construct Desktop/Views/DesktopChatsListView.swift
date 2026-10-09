//
//  DesktopChatsListView.swift
//  Construct Desktop (macOS only)
//
//  The iOS counterpart lives in ConstructMessenger/Views/Chats/ChatsListView.swift.
//  macOS: no NavigationStack — chat selection is driven through ChatsViewModel.chatToOpen,
//  which updates the detail column in DesktopRootView's NavigationSplitView.
//

import SwiftUI
import CoreData

struct DesktopChatsListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    /// The list's rows — values from `ChatStore`, in place of `@FetchRequest<Chat>` (chats C).
    private var chats: [ChatRecord] { ChatsLive.shared.chats() }

    @Environment(ChatsViewModel.self) private var chatsViewModel
    @State private var showingQRScanner = false
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var chatsViewModel = chatsViewModel
        VStack(spacing: 0) {
            searchBar
            chatList(selection: $chatsViewModel.chatToOpen)
        }
        .ctBackground()
        .sheet(isPresented: $showingQRScanner) {
            RecoveryGated { QRScannerView { contactURL in handleScannedContact(contactURL) } }
        }
        .onAppear {
            chatsViewModel.setContext(viewContext)
            consumeSidebarSearchFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteChat)) { note in
            guard let chatId = note.object as? String else { return }
            Task { await chatsViewModel.deleteChatForgettingSessions(chatId: chatId) }
        }
        .onChange(of: ChatsLive.shared.totalUnread, initial: true) { _, total in
            chatsViewModel.totalUnreadCount = total
        }
        .onChange(of: chatsViewModel.sidebarSearchFocused) { _, shouldFocus in
            guard shouldFocus else { return }
            consumeSidebarSearchFocus()
        }
        // ⌥⌘↓ / ⌥⌘↑ / ⌘1…9 are posted by the command bridge in DesktopRootView, which cannot
        // answer them: "the next chat" means the next one *as displayed*, and the order — pinned
        // first, then by last message, minus whatever the search box is filtering out — exists
        // only here. Until this observer the notifications had no listener and the shortcuts
        // silently did nothing.
        .onReceive(NotificationCenter.default.publisher(for: .desktopSelectNextChat)) { _ in
            selectChat(step: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .desktopSelectPrevChat)) { _ in
            selectChat(step: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .desktopJumpToChat)) { note in
            guard let index = note.object as? Int else { return }
            jumpToChat(index: index)
        }
    }

    // MARK: - Keyboard navigation

    /// The ids of the rows on screen, in the order they are drawn — pinned first, then by last
    /// message, minus whatever the search box is hiding. This ordering is the reason the keyboard
    /// shortcuts are answered here and not in `DesktopRootView`, which posts them.
    private var visibleChatIds: [String] { filteredChats.map(\.id) }

    private func selectChat(step: Int) {
        guard let next = ChatListNavigation.step(
            from: chatsViewModel.chatToOpen, by: step, in: visibleChatIds
        ) else { return }
        chatsViewModel.chatToOpen = next
    }

    private func jumpToChat(index: Int) {
        guard let target = ChatListNavigation.jump(to: index, in: visibleChatIds) else { return }
        chatsViewModel.chatToOpen = target
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack(spacing: 10) {
            ConnectionStatusIndicator()
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, CTLayout.navVPad)
        .ctBorderBottom()
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        CTSearchBar(text: $searchQuery, focused: $searchFocused)
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, 7)
            .background(Color.CT.bg)
            .ctBorderBottom()
    }

    private func consumeSidebarSearchFocus() {
        guard chatsViewModel.sidebarSearchFocused else { return }
        searchFocused = true
        chatsViewModel.sidebarSearchFocused = false
    }

    // MARK: - Chat List

    private var filteredChats: [ChatRecord] {
        guard !searchQuery.isEmpty else { return chats }
        return chats.filter { ChatsLive.matches($0, query: searchQuery) }
    }

    private func chatList(selection: Binding<String?>) -> some View {
        List(selection: selection) {
            ForEach(filteredChats, id: \.id) { chat in
                ChatRowView(chat: chat)
                    .tag(chat.id)
                    .desktopActiveRow(chatsViewModel.chatToOpen == chat.id)
                    .listRowSeparatorTint(Color.CT.noise)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await chatsViewModel.deleteChatForgettingSessions(chatId: chat.id) }
                        } label: {
                            Label(LocalizedStringKey("delete"), systemImage: "trash")
                        }
                        Button {
                            toggleMarkUnread(chat)
                        } label: {
                            Label(
                                LocalizedStringKey(chat.unreadCount > 0 ? "mark_read" : "mark_unread"),
                                systemImage: chat.unreadCount > 0 ? "envelope.open" : "envelope.badge"
                            )
                        }
                        Button {
                            togglePin(chat)
                        } label: {
                            Label(
                                LocalizedStringKey(chat.isPinned ? "unpin" : "pin"),
                                systemImage: chat.isPinned ? "pin.slash" : "pin"
                            )
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.CT.bg)
        .desktopSuppressSystemListSelection()
    }

    // MARK: - Actions

    private func togglePin(_ chat: ChatRecord) {
        try? LocalRepositories.chats.setPinned(chat.id, !chat.isPinned)
    }

    private func toggleMarkUnread(_ chat: ChatRecord) {
        try? LocalRepositories.chats.setUnread(chat.id, chat.unreadCount > 0 ? 0 : 1)
    }

    // MARK: - QR Code Handling

    private func handleScannedContact(_ urlString: String) {
        Log.info("🔍 DesktopChatsListView: Handling scanned URL: \(urlString)", category: "DesktopChatsListView")
        guard let url = URL(string: urlString) else {
            showErrorAfterDismiss(.said(UserText("invalid_qr_code_construct")))
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
                    showErrorAfterDismiss(AppError.from(error))
                    showingQRScanner = false
                }
            }
        }
    }

    private func addContact(contactInfo: ContactInfo) {
        let userId = contactInfo.userId
        let username = contactInfo.username
        if userId == AuthSessionManager.shared.currentUserId {
            return
        }
        if chatsViewModel.startChat(
            redeeming: contactInfo
        ) != nil {
            InviteRedeemUX.presentPostRedeemSafety(for: contactInfo)
        }
    }

    private func showErrorAfterDismiss(_ error: AppError) {
        showingQRScanner = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            ErrorRouter.shared.report(error)
        }
    }
}

// DEBUG only: the preview seeds `ChatsLive.useForPreview`, which a release build does not have.
#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)
    try? context.save()
    ChatsLive.useForPreview(container)
    ContactsLive.useForPreview(container)
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)
    return DesktopChatsListView()
        .environment(\.managedObjectContext, context)
        .environment(chatsViewModel)
        .frame(width: 280, height: 600)
}
#endif
