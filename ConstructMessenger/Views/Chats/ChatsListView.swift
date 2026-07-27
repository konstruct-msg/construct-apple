//
//  ChatsListView.swift
//  Construct Messenger
//

#if os(iOS)
import SwiftUI
import Combine
import CoreData

struct ChatsListView: View {
    private enum Layout {
        static let topScrimUnderSafeArea: CGFloat = CTLayout.navBarHeight + 24
    }

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel

    @FetchRequest
    private var chats: FetchedResults<Chat>

    @Environment(ChatsViewModel.self) private var chatsViewModel
    @State private var showingQRScanner = false
    @State private var showingMyQR = false
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
            ZStack {
                // Main list content - full height so it can scroll under floating capsules
                chatList(chats: renderedChats)

                GeometryReader { geo in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.CT.bg, location: 0),
                                    .init(color: Color.CT.bg.opacity(0.65), location: 0.55),
                                    .init(color: Color.CT.bg.opacity(0), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: geo.safeAreaInsets.top + Layout.topScrimUnderSafeArea)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)

                // Top floating area: nav + independent search capsule
                VStack(spacing: 0) {
                    navBar
                    searchBar
                        .padding(.horizontal, CTLayout.edgePad)
                        .padding(.top, 4)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .ctBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { chatId in
                    if let chat = chats.first(where: { $0.id == chatId }) {
                        ChatView(chat: chat, context: viewContext)
                            // Messenger convention: the bottom tab bar yields to the
                            // message input bar while inside a conversation.
                            .toolbar(.hidden, for: .tabBar)
                    }
            }
            .sheet(isPresented: $showingQRScanner) {
                    QRScannerView { contactURL in handleScannedContact(contactURL) }
            }
            .sheet(isPresented: $showingMyQR) {
                ContactQRCodeView(
                    userId: authViewModel.currentUserId
                        ?? AuthSessionManager.shared.currentUserId
                        ?? "",
                    username: authViewModel.currentUsername
                )
            }
            .onAppear {
                    chatsViewModel.setContext(viewContext)
                    LocalNotificationManager.shared.clearBadge()
                    updateTotalUnreadCount()
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
            // Total-unread badge only. Do NOT force-invalidate the List here (no
            // `.id(revision)`): the `@FetchRequest(animation: .default)` already drives
            // row inserts/deletes/reordering, and each `ChatRowView` observes its own
            // `chat`/`user`. Swapping the List's identity mid-animation raced the
            // coalesced UICollectionView batch update → "invalid number of items"
            // crash (device log 2026-07-19, during END_SESSION re-init + openOrCreateChat).
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { note in
                    guard notificationContainsChatChanges(note) else { return }
                    updateTotalUnreadCount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)) { note in
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
        HStack(spacing: CTLayout.chromeGap) {
            // Center the 8pt status dot on the same vertical axis as medium
            // chat-row avatars (40pt), so the header chrome lines up with the list.
            ConnectionStatusIndicator()
                .frame(width: CTHexAvatar.AvatarSize.medium.rawValue, alignment: .center)
            Spacer()
            Button { showingQRScanner = true } label: {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: CTLayout.navIconSize, weight: .medium))
                    .foregroundColor(Color.CT.accent)
                    .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("scan_qr_code", comment: ""))
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
    }

    // MARK: - Chat List

    private var filteredChats: [Chat] {
        // Dedupe by `id` before the `ForEach`: `@FetchRequest(animation:)` can transiently
        // surface the same Chat twice while a background-context merge (push-driven chat
        // insert) races the animated list update. A `ForEach` over a duplicate Identifiable
        // id trips UICollectionView's "invalid number of items" diff assertion → hard crash.
        let all = Self.dedupedByID(Array(chats))
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { chatMatchesQuery($0, query: query) }
    }

    /// Order-preserving dedupe of chats by `id` — the crash guard for the List diff assertion.
    private static func dedupedByID(_ items: [Chat]) -> [Chat] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func chatList(chats renderedChats: [Chat]) -> some View {
        List {
            // Spacer row at top so first chats are visible below the floating search capsule,
            // and content can scroll under the glass.
            Color.clear
                .frame(height: CTLayout.navBarHeight + CTLayout.controlHeight + 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if renderedChats.isEmpty {
                streamsEmptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(renderedChats) { chat in
                    Button {
                        navigationPath.append(chat.id)
                    } label: {
                        ChatRowView(chat: chat)
                    }
                    .buttonStyle(.plain)
                    // Clear so the CTMatrixBackground watermark shows through the rows.
                    .listRowBackground(Color.clear)
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
            // Spacer row so the last chat row is visible above the floating tab capsule,
            // and list content can scroll under the glass.
            Color.clear
                .frame(height: 72)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .refreshable {
            await BackgroundFetchManager.shared.fetchPendingMessages()
        }
        .scrollDismissesKeyboard(.immediately)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Align avatar column with nav chrome (edgePad) without zeroing vertical
        // list spacing — explicit listRowInsets(top/bottom: 0) had crushed the rows.
        .contentMargins(.horizontal, CTLayout.edgePad, for: .scrollContent)
        // ASCII matrix watermark behind the rows (base #090909 comes from .ctBackground()).
        .background(CTMatrixBackground())
    }

    /// Empty streams list — points users to invite paths (QR / Synaps).
    private var streamsEmptyState: some View {
        VStack(spacing: CTLayout.sectionGap) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.CT.textDim)
                .padding(.bottom, 4)

            Text(LocalizedStringKey("chats_empty_title"))
                .font(CTFont.bold(16))
                .foregroundStyle(Color.CT.text)
                .multilineTextAlignment(.center)

            Text(LocalizedStringKey("chats_empty_subtitle"))
                .font(CTFont.regular(13))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CTLayout.sectionGap)

            VStack(spacing: CTLayout.chromeGap) {
                emptyActionButton(
                    titleKey: "chats_empty_scan_qr",
                    systemImage: "qrcode.viewfinder"
                ) {
                    showingQRScanner = true
                }
                emptyActionButton(
                    titleKey: "chats_empty_show_qr",
                    systemImage: "qrcode"
                ) {
                    showingMyQR = true
                }
                emptyActionButton(
                    titleKey: "chats_empty_open_synaps",
                    systemImage: "circle.grid.cross"
                ) {
                    NotificationCenter.default.post(name: .openSynapsTab, object: nil)
                }
            }
            .padding(.top, CTLayout.inlinePad)
            .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, CTLayout.edgePad)
    }

    private func emptyActionButton(
        titleKey: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CTLayout.chromeGap) {
                Image(systemName: systemImage)
                    .font(.system(size: CTLayout.navIconSize, weight: .medium))
                Text(NSLocalizedString(titleKey, comment: "").uppercased())
                    .font(CTFont.bold(12))
                    .tracking(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.CT.textDim)
            }
            .foregroundStyle(Color.CT.accent)
            .padding(.horizontal, CTLayout.edgePad)
            .frame(minHeight: CTLayout.controlHeight)
            .background(Color.CT.bgMsg)
            .clipShape(CTShape.card())
            .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
            if objects.contains(where: { entity in
                let name = entity.entity.name
                return name == "Chat" || name == "Message"
            }) {
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
        if let chat = chatsViewModel.startChat(
            with: publicUserInfo,
            identityPublicKey: contactInfo.identityPublicKey
        ) {
            // Open the new/existing chat so scan feels like a completed action.
            chatsViewModel.chatToOpen = chat.id
            InviteRedeemUX.presentPostRedeemSafety(for: contactInfo)
        }
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
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "")
    let user3 = PreviewHelpers.createSampleUser(context: context, id: "b5257245-ab24-4765-b0ab-1098f599f957", username: "", displayName: "")
    _ = PreviewHelpers.createSampleChat(context: context, with: user1, unread: 12000)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2, unread: 33)
    _ = PreviewHelpers.createSampleChat(context: context, with: user3, unread: 1)
    try? context.save()
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)
    return ChatsListView()
        .environment(\.managedObjectContext, context)
        .environment(chatsViewModel)
}

#endif
