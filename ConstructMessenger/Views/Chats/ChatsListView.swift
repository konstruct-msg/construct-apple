//
//  ChatsListView.swift
//  Construct Messenger
//

#if os(iOS)
import SwiftUI
import CoreData

struct ChatsListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest
    private var chats: FetchedResults<Chat>

    @Environment(ChatsViewModel.self) private var chatsViewModel
    @State private var showingQRScanner = false
    @State private var navigationPath = NavigationPath()
    @State private var showingDrafts = false
    @State private var searchQuery = ""

    init() {
        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        fetchRequest.sortDescriptors = [
            NSSortDescriptor(keyPath: \Chat.isPinned, ascending: false),
            NSSortDescriptor(keyPath: \Chat.lastMessageTime, ascending: false)
        ]
        _chats = FetchRequest<Chat>(fetchRequest: fetchRequest, animation: .default)
    }

    var body: some View {
        let renderedChats = filteredChats
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                    navBar
                    searchBar
                    chatList(chats: renderedChats)
            }
            .ctBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { chatId in
                    if let chat = chats.first(where: { $0.id == chatId }) {
                        ChatView(chat: chat, context: viewContext)
                    }
            }
            .sheet(isPresented: $showingQRScanner) {
                    QRScannerView { contactURL in handleScannedContact(contactURL) }
            }
            .onAppear {
                    chatsViewModel.setContext(viewContext)
                    LocalNotificationManager.shared.clearBadge()
                    updateTotalUnreadCount()
            }
            .onChange(of: navigationPath) { _, path in
                    chatsViewModel.isInChat = !path.isEmpty
            }
            .onChange(of: chatsViewModel.chatToOpen) { _, chatId in
                    if let chatId {
                        chatsViewModel.chatToOpen = nil
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            navigationPath.append(chatId)
                        }
                    }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteChat)) { note in
                    guard let chatId = note.object as? String,
                          let chat = chats.first(where: { $0.id == chatId }) else { return }
                    Task { await chatsViewModel.deleteChatWithEndSession(chat: chat) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { note in
                    guard notificationContainsChatChanges(note) else { return }
                    updateTotalUnreadCount()
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        CTSearchBar(text: $searchQuery)
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack(spacing: 10) {
            ConnectionStatusIndicator()
            Spacer()
            Button { showingQRScanner = true } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: CTLayout.navIconSize, weight: .medium))
                    .foregroundColor(Color.CT.accent)
            }
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
        .ctBorderBottom()
    }

    // MARK: - Chat List

    private var filteredChats: [Chat] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(chats) }
        return chats.filter { chatMatchesQuery($0, query: query) }
    }

    private func chatList(chats renderedChats: [Chat]) -> some View {
        List {
            ForEach(renderedChats) { chat in
                Button {
                    navigationPath.append(chat.id)
                } label: {
                    ChatRowView(chat: chat)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.CT.bg)
                .listRowSeparatorTint(Color.CT.noise)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await chatsViewModel.deleteChatWithEndSession(chat: chat) }
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
                    .tint(Color.CT.accentDim)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        togglePin(chat)
                    } label: {
                        Label(
                            LocalizedStringKey(chat.isPinned ? "unpin" : "pin"),
                            systemImage: chat.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .tint(Color.CT.textDim)
                }
            }
        }
        .refreshable {
            await BackgroundFetchManager.shared.fetchPendingMessages()
        }
        .scrollDismissesKeyboard(.immediately)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.CT.bg)
    }

    // MARK: - Actions

    private func togglePin(_ chat: Chat) {
        chat.isPinned.toggle()
        try? viewContext.save()
    }

    private func toggleMarkUnread(_ chat: Chat) {
        chat.unreadCount = chat.unreadCount > 0 ? 0 : 1
        try? viewContext.save()
    }

    private func updateTotalUnreadCount() {
        chatsViewModel.totalUnreadCount = chats.reduce(0) { $0 + Int($1.unreadCount) }
    }

    private func notificationContainsChatChanges(_ note: Notification) -> Bool {
        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        for key in keys {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            if objects.contains(where: { $0.entity.name == "Chat" }) {
                return true
            }
        }
        return false
    }

    private func chatMatchesQuery(_ chat: Chat, query: String) -> Bool {
        let name = chat.otherUser?.resolvedDisplayName ?? ""
        let username = chat.otherUser?.username ?? ""
        let preview = chat.lastMessageText ?? ""
        return name.localizedCaseInsensitiveContains(query)
            || username.localizedCaseInsensitiveContains(query)
            || preview.localizedCaseInsensitiveContains(query)
    }

    // MARK: - QR Code Handling

    private func handleScannedContact(_ urlString: String) {
        Log.info("ChatsListView: Handling scanned URL: \(urlString)", category: "ChatsListView")
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
        let userId = contactInfo.userId
        let username = contactInfo.username
        if userId == AuthSessionManager.shared.currentUserId {
            showingDrafts = true
            return
        }
        let publicUserInfo = PublicUserInfo(
            id: userId,
            username: username,
            avatarUrl: nil,
            bio: nil,
            deviceId: contactInfo.deviceId
        )
        _ = chatsViewModel.startChat(with: publicUserInfo)
    }

    private func showErrorAfterDismiss(_ message: String) {
        showingQRScanner = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            ErrorRouter.shared.report(.unknown(message))
        }
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)
    try? context.save()
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)
    return ChatsListView()
        .environment(\.managedObjectContext, context)
        .environment(chatsViewModel)
}

#endif
