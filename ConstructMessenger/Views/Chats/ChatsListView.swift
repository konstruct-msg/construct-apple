//
//  ChatsListView.swift
//  Construct Messenger
//

#if os(iOS)
import SwiftUI
import Combine
import CoreData

struct ChatsListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(AuthViewModel.self) private var authViewModel
    /// Compact pushes a chat over the list; regular (the iPad) shows the list and the chat side
    /// by side — the system's split view, not a shell of our own (wave 5.5c, owner 2026-10-08).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @FetchRequest
    private var chats: FetchedResults<Chat>

    @Environment(ChatsViewModel.self) private var chatsViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryViewModel
    @State private var showingRecoveryBackup = false
    @State private var showingQRScanner = false
    @State private var showingMyQR = false
    @State private var navigationPath = NavigationPath()
    /// The chat in the split view's detail, at regular width.
    @State private var selectedChatId: String?
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
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                listColumn
            } detail: {
                chatDetail
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: $navigationPath) {
                listColumn
                    .navigationDestination(for: String.self) { chatId in
                        if let chat = chats.first(where: { $0.id == chatId }) {
                            // Messenger convention: the bottom tab bar yields to the message
                            // input bar while inside a conversation — `ChatView` hides it.
                            ChatView(chat: chat, context: viewContext)
                        }
                    }
            }
        }
    }

    /// The open chat beside the list. A stack of its own so the chat's bar has somewhere to be,
    /// one per chat so switching chats starts fresh.
    @ViewBuilder
    private var chatDetail: some View {
        if let chatId = selectedChatId, let chat = chats.first(where: { $0.id == chatId }) {
            NavigationStack {
                ChatView(chat: chat, context: viewContext)
            }
            .id(chat.id)
        } else {
            ContentUnavailableView(
                String(localized: "select_chat"),
                systemImage: "message",
                description: Text("select_chat_description")
            )
            .ctBackground()
        }
    }

    /// Opens a chat: pushed over the list on the phone, beside it on the iPad.
    private func open(_ chatId: String) {
        if horizontalSizeClass == .regular {
            selectedChatId = chatId
        } else {
            navigationPath.append(chatId)
        }
    }

    private var listColumn: some View {
        let renderedChats = filteredChats
        return chatList(chats: renderedChats)
            .ctBackground()
            .navigationTitle(NSLocalizedString("chats", comment: ""))
            .inlineNavTitle()
            .connectionSubtitle()
            .searchable(text: $searchQuery, prompt: Text(LocalizedStringKey("search_prompt")))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingQRScanner = true } label: {
                        Label(NSLocalizedString("scan_qr_code", comment: ""), systemImage: "qrcode.viewfinder")
                    }
                    .barItem()
                    .accessibilityIdentifier(A11y.Chats.scanQR)
                }
            }
            .sheet(isPresented: $showingQRScanner) {
                    RecoveryGated { QRScannerView { contactURL in handleScannedContact(contactURL) } }
            }
            .sheet(isPresented: $showingRecoveryBackup, onDismiss: {
                recoveryViewModel.refreshBackupPending()
            }) {
                RecoverySetupView().sheetNavigation(closes: false)
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
                    recoveryViewModel.refreshBackupPending()
                    chatsViewModel.setContext(viewContext)
                    LocalNotificationManager.shared.clearBadge()
                    reconcileStalePreviews(from: nil)
                    updateTotalUnreadCount()
            }
            .onChange(of: chatsViewModel.chatToOpen) { _, chatId in
                    if let chatId {
                        chatsViewModel.chatToOpen = nil
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            open(chatId)
                        }
                    }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteChat)) { note in
                    guard let chatId = note.object as? String,
                          let chat = chats.first(where: { $0.id == chatId }) else { return }
                    if selectedChatId == chatId { selectedChatId = nil }
                    Task { await chatsViewModel.deleteChatForgettingSessions(chat: chat) }
            }
            // Total-unread badge only. Do NOT force-invalidate the List here (no
            // `.id(revision)`): the `@FetchRequest(animation: .default)` already drives
            // row inserts/deletes/reordering, and each `ChatRowView` observes its own
            // `chat`/`user`. Swapping the List's identity mid-animation raced the
            // coalesced UICollectionView batch update → "invalid number of items"
            // crash (device log 2026-07-19, during END_SESSION re-init + openOrCreateChat).
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)) { note in
                    guard notificationContainsChatChanges(note) else { return }
                    // After a message write, denormalized previews can lag (missed applyPreview
                    // or observation gap). Touch only chats present in the save.
                    reconcileStalePreviews(from: note)
                    updateTotalUnreadCount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange)) { note in
                    guard notificationContainsChatChanges(note) else { return }
                    updateTotalUnreadCount()
            }
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

    private func isOpenBeside(_ chat: Chat) -> Bool {
        horizontalSizeClass == .regular && selectedChatId == chat.id
    }

    /// Order-preserving dedupe of chats by `id` — the crash guard for the List diff assertion.
    private static func dedupedByID(_ items: [Chat]) -> [Chat] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func chatList(chats renderedChats: [Chat]) -> some View {
        List {
            if recoveryViewModel.reminder != .none {
                RecoveryReminderRow(
                    reminder: recoveryViewModel.reminder,
                    onOpen: { showingRecoveryBackup = true },
                    onDismiss: { recoveryViewModel.snoozeReminder() }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if renderedChats.isEmpty {
                streamsEmptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(renderedChats) { chat in
                    Button {
                        open(chat.id)
                    } label: {
                        ChatRowView(chat: chat)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(A11y.Chats.row(chat.id))
                    .accessibilityAddTraits(isOpenBeside(chat) ? .isSelected : [])
                    // Clear so the CTMatrixBackground watermark shows through the rows; the chat
                    // open beside the list (iPad) is marked as the selection.
                    .listRowBackground(isOpenBeside(chat) ? Color.CT.bgMsg : Color.clear)
                    .listRowSeparatorTint(Color.CT.noise)
                    // The first row's top hairline sat under a spacer row while the list scrolled
                    // under a floating header; with the system bar it would be the bar's edge.
                    .listRowSeparator(chat.id == renderedChats.first?.id ? .hidden : .automatic, edges: .top)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if selectedChatId == chat.id { selectedChatId = nil }
                            Task { await chatsViewModel.deleteChatForgettingSessions(chat: chat) }
                        } label: {
                            Label(LocalizedStringKey("delete"), systemImage: "trash")
                        }
                        // Stated, not inherited. `role: .destructive` colours a swipe action red
                        // only while nothing above it names a tint; `MainTabView` applies
                        // `.tint(Color.CT.accent)` to the whole tab view, so this button came out
                        // the same blue as "mark unread" beside it and stopped reading as the
                        // destructive one. Its two neighbours already state their colour — this
                        // was the only button in the group that did not.
                        .tint(Color.CT.danger)
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
        .accessibilityIdentifier(A11y.Chats.list)
    }

    /// Empty streams list — points users to invite paths (QR / Synaps).
    private var streamsEmptyState: some View {
        ContentUnavailableView {
            Label {
                Text(LocalizedStringKey("chats_empty_title"))
                    .font(CTFont.headline)
            } icon: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
        } description: {
            Text(LocalizedStringKey("chats_empty_subtitle"))
                .font(CTFont.body)
        } actions: {
            Button {
                showingQRScanner = true
            } label: {
                Label(LocalizedStringKey("chats_empty_scan_qr"), systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(A11y.Chats.emptyScanQR)
            Button {
                showingMyQR = true
            } label: {
                Label(LocalizedStringKey("chats_empty_show_qr"), systemImage: "qrcode")
            }
            .accessibilityIdentifier(A11y.Chats.emptyShowQR)
            Button {
                NotificationCenter.default.post(name: .openSynapsTab, object: nil)
            } label: {
                Label(LocalizedStringKey("chats_empty_open_synaps"), systemImage: "circle.grid.cross")
            }
            .accessibilityIdentifier(A11y.Chats.emptyOpenSynaps)
        }
        .font(CTFont.body)
        .accessibilityIdentifier(A11y.Chats.empty)
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

    /// Re-align denormalized list previews with each chat's newest transcript message.
    /// No-op when already in sync; saves once if any row was repaired.
    /// - Parameter note: when non-nil, only chats touched by that save are scanned.
    private func reconcileStalePreviews(from note: Notification?) {
        let targets: [Chat]
        if let note {
            targets = chatsTouchedBySave(note)
            guard !targets.isEmpty else { return }
        } else {
            targets = Array(chats)
        }
        var changed = false
        for chat in targets {
            if chat.reconcilePreviewFromTranscript(in: viewContext) {
                changed = true
            }
        }
        if changed {
            viewContext.saveAndLog()
        }
    }

    private func chatsTouchedBySave(_ note: Notification) -> [Chat] {
        var ids = Set<NSManagedObjectID>()
        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey] {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            for obj in objects {
                if let msg = obj as? Message, let chat = msg.chat {
                    ids.insert(chat.objectID)
                } else if obj is Chat {
                    ids.insert(obj.objectID)
                }
            }
        }
        return ids.compactMap { try? viewContext.existingObject(with: $0) as? Chat }
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
        // A voucher scanned here is a voucher, not a malformed contact code.
        if let outcome = VeilVoucherRedemption.messageIfVoucher(urlString) {
            showingQRScanner = false
            showErrorAfterDismiss(outcome)
            return
        }
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
        if userId == AuthSessionManager.shared.currentUserId {
            showingDrafts = true
            return
        }
        if let chat = chatsViewModel.startChat(
            redeeming: contactInfo
        ) {
            // Open the new/existing chat so scan feels like a completed action.
            chatsViewModel.chatToOpen = chat.id
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
