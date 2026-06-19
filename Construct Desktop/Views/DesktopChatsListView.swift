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

    @FetchRequest
    private var chats: FetchedResults<Chat>

    @Environment(ChatsViewModel.self) private var chatsViewModel
    @State private var showingQRScanner = false
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
        VStack(spacing: 0) {
//            navBar
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
        TextField("", text: $searchQuery, prompt: Text(LocalizedStringKey("Search..."))
            .foregroundColor(Color.CT.textDim))
            .textFieldStyle(.plain)
            .font(CTFont.regular(12))
            .foregroundColor(Color.CT.text)
            .autocorrectionDisabled()
            .tint(Color.CT.accent)
            .padding(.leading, 10)
            .padding(.trailing, 32)
            .padding(.vertical, 7)
            .overlay(alignment: .trailing) {
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.CT.textDim)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .background(Color.CT.bgMsg, in: Capsule())
            .overlay { Capsule().stroke(Color.CT.noise, lineWidth: 1) }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.CT.bg)
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
                    chatsViewModel.chatToOpen = chat.id
                } label: {
                    ChatRowView(chat: chat)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.CT.bg)
                .listRowSeparatorTint(Color.CT.noise)
                .contextMenu {
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
        Log.info("🔍 DesktopChatsListView: Handling scanned URL: \(urlString)", category: "DesktopChatsListView")
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
    return DesktopChatsListView()
        .environment(\.managedObjectContext, context)
        .environment(chatsViewModel)
        .frame(width: 280, height: 600)
}
