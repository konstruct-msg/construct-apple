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

    /// The list's rows — values from `ChatStore`, in place of `@FetchRequest<Chat>` (chats C).
    private var chats: [ChatRecord] { ChatsLive.shared.chats() }

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
                        // The conversation still takes the managed chat — the messages domain
                        // moves it — so the open chat is the one bridge to it.
                        if let chat = try? Chat.row(chatId, in: viewContext) {
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
        if let chatId = selectedChatId, let chat = try? Chat.row(chatId, in: viewContext) {
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
                    guard let chatId = note.object as? String else { return }
                    if selectedChatId == chatId { selectedChatId = nil }
                    Task { await chatsViewModel.deleteChatForgettingSessions(chatId: chatId) }
            }
            // Do NOT force-invalidate the List (no `.id(revision)`): the rows' ids drive inserts,
            // deletes and reordering. Swapping the List's identity mid-animation raced the
            // coalesced UICollectionView batch update → "invalid number of items" crash (device
            // log 2026-07-19, during END_SESSION re-init + openOrCreateChat).
            .onChange(of: ChatsLive.shared.revision) { _, _ in updateTotalUnreadCount() }
            // On the main queue: repositories save on their own background contexts, and this
            // touches the view context.
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: DispatchQueue.main)) { note in
                    guard notificationContainsChatChanges(note) else { return }
                    // After a message write, denormalized previews can lag (missed writer or a
                    // frozen stamp). Touch only chats present in the save.
                    reconcileStalePreviews(from: note)
            }
    }

    // MARK: - Chat List

    /// Ids are unique in the store, so the `ForEach` needs no dedupe: the `@FetchRequest` this
    /// replaced could surface one chat twice while a merge raced the animated update.
    private var filteredChats: [ChatRecord] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chats }
        return chats.filter { ChatsLive.matches($0, query: query) }
    }

    private func isOpenBeside(_ chat: ChatRecord) -> Bool {
        horizontalSizeClass == .regular && selectedChatId == chat.id
    }

    private func chatList(chats renderedChats: [ChatRecord]) -> some View {
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
                            Task { await chatsViewModel.deleteChatForgettingSessions(chatId: chat.id) }
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

    private func togglePin(_ chat: ChatRecord) {
        try? LocalRepositories.chats.setPinned(chat.id, !chat.isPinned)
    }

    private func toggleMarkUnread(_ chat: ChatRecord) {
        try? LocalRepositories.chats.setUnread(chat.id, chat.unreadCount > 0 ? 0 : 1)
    }

    private func updateTotalUnreadCount() {
        chatsViewModel.totalUnreadCount = ChatsLive.shared.totalUnread
    }

    /// Re-align denormalized list previews with each chat's newest transcript message.
    /// No-op when already in sync; a repair is written through `ChatStore`.
    /// - Parameter note: when non-nil, only chats touched by that save are scanned.
    private func reconcileStalePreviews(from note: Notification?) {
        let targets: [Chat]
        if let note {
            targets = chatsTouchedBySave(note)
            guard !targets.isEmpty else { return }
        } else {
            targets = chats.compactMap { try? Chat.row($0.id, in: viewContext) }
        }
        for chat in targets {
            chat.reconcilePreviewFromTranscript(in: viewContext)
        }
    }

    /// The saving context may be another queue's, so only object ids are read from the note —
    /// they cross threads — and each is resolved in the view context.
    private func chatsTouchedBySave(_ note: Notification) -> [Chat] {
        var chatIds = Set<NSManagedObjectID>()
        var messageIds = Set<NSManagedObjectID>()
        for key in [NSInsertedObjectsKey, NSUpdatedObjectsKey] {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            for obj in objects {
                switch obj.objectID.entity.name {
                case "Message": messageIds.insert(obj.objectID)
                case "Chat":    chatIds.insert(obj.objectID)
                default:        break
                }
            }
        }
        for id in messageIds {
            if let chat = (try? viewContext.existingObject(with: id) as? Message)?.chat {
                chatIds.insert(chat.objectID)
            }
        }
        return chatIds.compactMap { try? viewContext.existingObject(with: $0) as? Chat }
    }

    private func notificationContainsChatChanges(_ note: Notification) -> Bool {
        let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        for key in keys {
            guard let objects = note.userInfo?[key] as? Set<NSManagedObject> else { continue }
            if objects.contains(where: { entity in
                let name = entity.objectID.entity.name
                return name == "Chat" || name == "Message"
            }) {
                return true
            }
        }
        return false
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

// DEBUG only: the preview seeds `ChatsLive.useForPreview`, which a release build does not have.
#if DEBUG
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
    ChatsLive.useForPreview(container)
    ContactsLive.useForPreview(container)
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)
    return ChatsListView()
        .environment(\.managedObjectContext, context)
        .environment(chatsViewModel)
}
#endif

#endif
