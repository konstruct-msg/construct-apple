//
//  ChatsListView.swift
//  Construct Messenger
//

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
        #if os(iOS)
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                navBar
                searchBar
                chatList
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
            .onChange(of: chats.reduce(0, { $0 + Int($1.unreadCount) })) { _, total in
                chatsViewModel.totalUnreadCount = total
            }
        }
        #else
        // macOS: no NavigationStack — chat selection drives the detail column
        // in NavigationSplitView via chatsViewModel.chatToOpen.
        VStack(spacing: 0) {
            navBar
            searchBar
            chatList
        }
        .ctBackground()
        .sheet(isPresented: $showingQRScanner) {
            QRScannerView { contactURL in handleScannedContact(contactURL) }
        }
        .onAppear {
            chatsViewModel.setContext(viewContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .deleteChat)) { note in
            guard let chatId = note.object as? String,
                  let chat = chats.first(where: { $0.id == chatId }) else { return }
            Task { await chatsViewModel.deleteChatWithEndSession(chat: chat) }
        }
        .onChange(of: chats.reduce(0, { $0 + Int($1.unreadCount) })) { _, total in
            chatsViewModel.totalUnreadCount = total
        }
        #endif
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Text("[")
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
            TextField("", text: $searchQuery, prompt: Text("search_")
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.text)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .tint(Color.CT.accent)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Text("×")
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                }
            } else {
                Text("]")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.CT.bgMsg)
        .ctBorderBottom()
    }

    // MARK: - Nav Bar

    private var navBar: some View {
        HStack(spacing: 10) {
            ConnectionStatusIndicator()
            Spacer()
            #if os(iOS)
            Button { showingQRScanner = true } label: {
                Text(CTSymbol.scan)
                    .font(CTFont.bold(14))
                    .foregroundColor(Color.CT.accent)
            }
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .ctBorderBottom()
    }

    // MARK: - Chat List

    private var filteredChats: [Chat] {
        guard !searchQuery.isEmpty else { return Array(chats) }
        let q = searchQuery.lowercased()
        return chats.filter { chat in
            let name = (chat.otherUser?.resolvedDisplayName ?? "").lowercased()
            let username = (chat.otherUser?.username ?? "").lowercased()
            let preview = (chat.lastMessageText ?? "").lowercased()
            return name.contains(q) || username.contains(q) || preview.contains(q)
        }
    }

    private var chatList: some View {
        List {
            ForEach(filteredChats) { chat in
                Button {
                    #if os(iOS)
                    navigationPath.append(chat.id)
                    #else
                    chatsViewModel.chatToOpen = chat.id
                    #endif
                } label: {
                    ChatRowView(chat: chat)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.CT.bg)
                .listRowSeparatorTint(Color.CT.noise)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
            #if os(iOS)
            await BackgroundFetchManager.shared.fetchPendingMessages()
            #endif
        }
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

    // MARK: - QR Code Handling

    private func handleScannedContact(_ urlString: String) {
        Log.info("🔍 ChatsListView: Handling scanned URL: \(urlString)", category: "ChatsListView")
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
        if userId == SessionManager.shared.currentUserId {
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
