//
//  DesktopChatView.swift
//  Construct Desktop
//
//  macOS-only chat screen.  Mirrors the structure of the shared ChatView but
//  without any platform-conditional blocks — the result is cleaner and easier
//  to iterate on independently from the iOS counterpart.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct DesktopChatView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(ChatsViewModel.self) private var chatsViewModel
    /// Lazy holder — avoid allocating ChatViewModel in View.init (parent re-render churn).
    @State private var lazyViewModel: LazyChatViewModel
    private var viewModel: ChatViewModel { lazyViewModel.value }
    private var peerId: String { viewModel.conversation.peerId }
    @State private var scrollManager = ChatScrollManager()
    private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State private var replyingTo: TranscriptRow?
    @State private var replyQuoteText: String? = nil
    @State private var quotingMessage: TranscriptRow? = nil
    @State private var replyFocusIds: Set<String> = []
    @State private var replyFocusPeekTask: Task<Void, Never>?
    @State private var showingUserProfile = false
    @State private var callManager = CallManager.shared

    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var isEditMode = false
    @State private var selectedMessages: Set<String> = []
    /// What the forward picker on screen will send.
    @State private var forwarding: [TranscriptRow] = []
    @State private var showingForwardPicker = false
    @State private var forwardFailed = false
    @State private var galleryStartItem: GalleryStartItem?

    @State private var chatDropImages: [PlatformImage] = []
    @State private var chatDropFileURLs: [URL] = []
    @State private var isChatDropTargeted = false

    @State private var floodGuard = IncomingFloodGuard.shared
    @State private var contactKTStatus: KTStatus = .unverified
    @State private var contactTrustAlert: ContactTrustAlert?
    @State private var isSessionAtRisk = false
    @State private var containerWidth: CGFloat = 800

    init(conversation: Conversation, context: NSManagedObjectContext) {
        _lazyViewModel = State(wrappedValue: LazyChatViewModel {
            ChatViewModel(conversation: conversation, context: context)
        })
    }

    var body: some View {
        ZStack() {
            ChatTranscriptContainer(
                rowSpacing: 0,
                // Native window toolbar owns the top chrome; this is breathing room,
                // not clearance for a floating iOS capsule (that was 70).
                topContentPad: CTLayout.edgePad,
                bottomContentPad: 130,
                accessibilityIdentifier: nil,
                onProxyReady: registerTranscriptProxy,
                onGeometryChange: handleTranscriptGeometry,
                onScrollPhaseChange: handleTranscriptScrollPhase,
                onTapBackground: hideKeyboard,
                onBottomAnchorVisible: { _ in },
                sentinel: { loadMoreSentinel },
                rows: { transcriptRows }
            )
            .environment(\.containerWidth, containerWidth)
                .onChange(of: viewModel.entries.count) { oldCount, count in
                    // Shared with iOS ChatView: open / corrective pin / animated follow.
                    scrollManager.handleTranscriptCountChange(
                        oldCount: oldCount,
                        newCount: count,
                        searchActive: isSearchActive
                    )
                }
                .onChange(of: scrollManager.isOpening) { _, opening in
                    if !opening {
                        attemptLoadOlderHistory()
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    if !newValue.isEmpty, let first = filteredMessages.first {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(ChatViewConstants.SearchDelay.scrollToResult))
                            scrollManager.scrollTo(messageId: first.id, anchor: .center)
                        }
                    } else if newValue.isEmpty {
                        scrollManager.shouldScrollToBottom = true
                        scrollManager.scrollToBottom()
                    }
                }
                .onChange(of: isSearchActive) { _, active in
                    if active {
                        if isEditMode { isEditMode = false; selectedMessages.removeAll() }
                    } else {
                        searchText = ""
                        scrollManager.shouldScrollToBottom = true
                        scrollManager.scrollToBottom()
                    }
                }
                .onChange(of: isEditMode) { _, editMode in
                    if editMode && isSearchActive { isSearchActive = false; searchText = "" }
                }
                .onChange(of: viewModel.editingMessage) { _, editMsg in
                    if let editMsg {
                        // A media message edits its caption.
                        messageText = editMsg.readableText
                    }
                }
        
        
            VStack(spacing: 10) {
                floodBurstBanner
                atRiskBanner

                deleteButtonBar
                
                Spacer(minLength: 0)
                
                messageInputView
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            // macOS: deterministic size for NSSplitView constraint stability
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.image, .fileURL], isTargeted: $isChatDropTargeted) { providers in
                handleChatDrop(providers: providers)
            }
            .overlay {
                if isChatDropTargeted {
                    Rectangle()
                        .strokeBorder(Color.CT.accent, lineWidth: 2)
                        .background(Color.CT.accent.opacity(0.05))
                        .overlay(
                            Text(LocalizedStringKey("drop_to_attach"))
                                .font(CTFont.ui(16))
                                .foregroundColor(Color.CT.accent)
                                .padding(16)
                                .background(Color.CT.bgMsg)
                                .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 1))
                        )
                        .allowsHitTesting(false)
                        .padding(8)
                }
            }
            .sheet(isPresented: $showingForwardPicker) {
                ForwardPickerView(onPick: finishForward(to:))
                    .sheetNavigation()
                    .frame(minWidth: 420, minHeight: 480)
            }
            .task(id: ForwardDrafts.shared.pending[viewModel.conversation.chatId]?.count ?? 0) {
                await sendForwardedHere()
            }
            .alert(NSLocalizedString("forward_failed", comment: ""), isPresented: $forwardFailed) {
                Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
            }
            .sheet(isPresented: $showingUserProfile) {
                UserProfileView(userId: peerId, showMessageButton: false)
                    .sheetNavigation()
                    .environment(\.managedObjectContext, viewContext)
                    .frame(minWidth: 420, minHeight: 480)
            }
            .sheet(item: $quotingMessage) { msg in
                QuoteSelectionSheet(message: msg) { selectedQuote in
                    replyingTo = msg
                    replyQuoteText = selectedQuote
                    setComposeReplyFocus(messageId: msg.id)
                }
                .sheetNavigation()
                .frame(minWidth: 400, minHeight: 320)
            }
            .sheet(item: $galleryStartItem) { item in
                DesktopMediaViewer(
                    messages: mediaMessages,
                    initialMessageId: item.messageId,
                    initialItemIndex: item.itemIndex,
                    isPresented: Binding(
                        get: { galleryStartItem != nil },
                        set: { if !$0 { galleryStartItem = nil } }
                    )
                )
            }
            .onChange(of: chatsViewModel.pendingDroppedImage) { _, image in
                guard let image else { return }
                chatDropImages.append(image)
                chatsViewModel.pendingDroppedImage = nil
            }
            .onChange(of: chatsViewModel.pendingDroppedFileURL) { _, url in
                guard let url else { return }
                chatDropFileURLs.append(url)
                chatsViewModel.pendingDroppedFileURL = nil
            }
            .onChange(of: viewModel.isInitializingSession) { _, _ in refreshSessionAtRiskState() }
            .onReceive(NotificationCenter.default.publisher(for: .sessionAtRiskChanged)) { note in
                if (note.userInfo?["userId"] as? String) == peerId {
                    refreshSessionAtRiskState()
                }
            }
            .onAppear {
                guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
                markChatAsRead()
                viewModel.onViewAppear()
                loadContactKTStatus()
                refreshSessionAtRiskState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .contactKeyChanged)) { note in
                guard let changedId = note.userInfo?["userId"] as? String,
                      changedId == peerId else { return }
                loadContactKTStatus()
            }
            .onDisappear {
                replyFocusPeekTask?.cancel()
                replyFocusPeekTask = nil
            }
            .alert(callManager.lastError ?? "", isPresented: Binding(
                get: { callManager.lastError != nil },
                set: { if !$0 { callManager.clearLastError() } }
            )) {
                Button(NSLocalizedString("ok", comment: ""), role: .cancel) {
                    callManager.clearLastError()
                }
            }
        }
        .modifier(DesktopChatWindowTitle(
            userId: peerId,
            fallback: NSLocalizedString("chat", comment: "")
        ))
        // The window keeps its title (the Window menu, Mission Control); the toolbar shows
        // `chatTitle` instead, so the key status can stand next to the name.
        .toolbar(removing: .title)
        .toolbar { chatToolbar }
        .onChange(of: chatsViewModel.chatSearchPresented) { _, presented in
            guard presented else { return }
            isSearchActive = true
            chatsViewModel.chatSearchPresented = false
        }
    }

    // MARK: - View Components

    private var atRiskBanner: some View {
        ChatAtRiskBannerView(isVisible: isSessionAtRisk)
    }

    private func refreshSessionAtRiskState() {
        let contactId = peerId
        isSessionAtRisk = KeychainManager.shared.loadSessionAtRiskFlag(for: contactId)
    }

    @ViewBuilder
    private var floodBurstBanner: some View {
        let senderId = peerId
        if floodGuard.suppressedSenders.contains(senderId) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(CTFont.ui(16))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("flood_banner_title"))
                        .font(.footnote.weight(.semibold))
                    Text(LocalizedStringKey("flood_banner_subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    IncomingFloodGuard.shared.unsuppress(senderId: senderId)
                } label: {
                    Label(NSLocalizedString("allow", comment: ""), systemImage: "checkmark.circle")
                        .font(CTFont.secondary)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)

                Button {
                    try? LocalRepositories.contacts.setBlocked(peerId, true)
                    IncomingFloodGuard.shared.unsuppress(senderId: senderId)
                } label: {
                    Label(NSLocalizedString("block_user", comment: ""), systemImage: "hand.raised.fill")
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.danger)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .bottom)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var deleteButtonBar: some View {
        if isEditMode && !selectedMessages.isEmpty {
            HStack {
                Button(role: .destructive) {
                    deleteSelectedMessages()
                } label: {
                    Label(NSLocalizedString("delete_selected", comment: ""), systemImage: "trash")
                        .font(CTFont.ui(13, weight: .medium, relativeTo: .footnote))
                        .foregroundStyle(Color.CT.danger)
                }
                Spacer()
                Text(
                    "\(selectedMessages.count) \(NSLocalizedString(selectedMessages.count == 1 ? "message_selected" : "messages_selected", comment: ""))"
                )
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
                Spacer()
                Button {
                    startForward(viewModel.entries.map(\.row).filter { selectedMessages.contains($0.id) })
                } label: {
                    Label(NSLocalizedString("forward", comment: ""), systemImage: "arrowshape.turn.up.right")
                }
            }
            .padding()
            .background(Color.CT.bg)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.CT.accent.opacity(0.3)), alignment: .top)
        }
    }

    private var messageInputView: some View {
        MessageInputView(
            text: $messageText,
            droppedImages: $chatDropImages,
            droppedFileURLs: $chatDropFileURLs,
            replyingTo: replyingTo,
            quoteOverride: replyQuoteText,
            editingMessage: viewModel.editingMessage,
            onSend: { attachments, fileURLs in
                if let editMsg = viewModel.editingMessage {
                    let safeToEdit = editMsg.deliveryStatus != .sending && editMsg.deliveryStatus != .queued
                    guard safeToEdit else {
                        viewModel.editingMessage = nil
                        messageText = ""
                        return
                    }
                    viewModel.editMessage(editMsg, newText: messageText)
                    messageText = ""
                } else {
                    viewModel.sendMessage(
                        text: messageText,
                        attachments: attachments,
                        fileURLs: fileURLs,
                        replyTo: replyingTo,
                        replyToContentOverride: replyQuoteText
                    )
                    messageText = ""
                    replyingTo = nil
                    replyQuoteText = nil
                    clearReplyFocus(animated: true)
                    // Follow newest via messages.count onChange — not a second delayed scroll here.
                    scrollManager.shouldScrollToBottom = true
                }
            },
            onSendVoice: { url, duration, waveform in
                viewModel.sendVoiceMessage(url: url, duration: duration, waveform: waveform)
                scrollManager.shouldScrollToBottom = true
            },
            onCancelReply: {
                replyingTo = nil
                replyQuoteText = nil
                clearReplyFocus(animated: true)
            },
            onCancelEdit: {
                viewModel.editingMessage = nil
                messageText = ""
            }
        )
        .disabled(isEditMode)
        .overlay(alignment: .bottomTrailing) {
            if scrollManager.shouldShowScrollToBottomButton && !isEditMode {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        scrollManager.scrollToBottom()
                        scrollManager.shouldScrollToBottom = true
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(CTFont.ui(32, weight: .semibold))
                            .foregroundStyle(Color.CT.accent, Color.CT.bg.opacity(0.85))
                        if (ChatsLive.shared.chat(viewModel.conversation.chatId)?.unreadCount ?? 0) > 0 {
                            Circle()
                                .fill(Color.CT.danger)
                                .frame(width: 10, height: 10)
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
                .padding(.bottom, 80)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrollManager.shouldShowScrollToBottomButton)
            }
        }
    }

    // MARK: - Window toolbar (D1)

    //
    // The name, our own connection state under it, and the key status beside it are the title —
    // status, not controls, so no glass under them (macOS 26 groups neighbouring items into one
    // capsule, and the badge read as a second button next to the profile). Nothing about the
    // peer's presence: there is none to show. The right side is only controls.

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { chatTitle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { chatTitle }
        }

        ToolbarItem(placement: .primaryAction) {
            if isSearchActive {
                DesktopToolbarSearchField(
                    text: $searchText,
                    prompt: NSLocalizedString("search_messages", comment: ""),
                    onEnd: { isSearchActive = false }
                )
                .frame(width: Self.searchFieldWidth)
            } else {
                Button {
                    isSearchActive = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help(NSLocalizedString("search_messages", comment: ""))
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showingUserProfile = true
            } label: {
                Image(systemName: "info.circle")
            }
            .help(NSLocalizedString("profile", comment: ""))
        }

        if isEditMode {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { isEditMode = false; selectedMessages.removeAll() }
                } label: {
                    Image(systemName: "checkmark")
                }
                .help(NSLocalizedString("done", comment: ""))
            }
        } else if CallsFeature.isEnabled,
                  case .idle = callManager.state {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await callManager.startOutgoingCall(
                            to: peerId,
                            displayName: ContactsLive.shared.contact(peerId)?.resolvedDisplayName
                                ?? DisplayNameGenerator.generate(from: peerId),
                            hasVideo: false
                        )
                    }
                } label: {
                    Image(systemName: "phone")
                }
                .help(NSLocalizedString("call_voice", comment: ""))
            }
        }
    }

    private static let searchFieldWidth: CGFloat = 220

    private var chatTitle: some View {
        HStack(spacing: CTSpace.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(titleName)
                    .font(CTFont.headline)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
                if let subtitle = navigationStatusSubtitle {
                    Text(subtitle)
                        .font(CTFont.caption)
                        .foregroundStyle(Color.CT.textDim)
                        .lineLimit(1)
                }
            }
            ktBadge
        }
        .padding(.horizontal, CTSpace.xs)
    }

    private var titleName: String {
        guard !peerId.isEmpty else { return NSLocalizedString("chat", comment: "") }
        return ContactsLive.shared.contact(peerId)?.resolvedDisplayName
            ?? DisplayNameGenerator.generate(from: peerId)
    }

    @ViewBuilder private var ktBadge: some View {
        if let alert = contactTrustAlert {
            CTStatusBadge(status: alert == .verificationFailed ? .error : .warning, size: 12)
                .help(NSLocalizedString(alert.titleKey, comment: ""))
                .accessibilityLabel(Text(NSLocalizedString("kt_warning", comment: "")))
        } else if contactKTStatus == .verified {
            CTStatusBadge(status: .ok, size: 12)
                .help(NSLocalizedString("kt_verified", comment: ""))
                .accessibilityLabel(Text(NSLocalizedString("kt_verified", comment: "")))
        }
    }

    private var navigationStatusSubtitle: String? {
        if viewModel.isInitializingSession {
            return NSLocalizedString("status_encrypting", comment: "")
        } else if connectionManager.connectionStatus == .connecting {
            return NSLocalizedString("status_connecting", comment: "")
        } else if !connectionManager.isConnected {
            return NSLocalizedString("status_no_connection", comment: "")
        }
        return nil
    }

    // MARK: - Computed Properties

    private var filteredMessages: [TranscriptEntry] {
        let valid = viewModel.entries
        guard !searchText.isEmpty else { return valid }
        // The words, not the stored body: "mediaId" would match every photo. Reads every row, so
        // the list follows every row while a search is open — only then.
        return valid.filter { $0.row.readableText.localizedCaseInsensitiveContains(searchText) }
    }

    private var mediaMessages: [TranscriptRow] {
        viewModel.messages.filter {
            if let mc = parseMediaContent(from: $0.legacyBody) {
                return (mc.media["_placeholder"] as? Bool) != true
            }
            return false
        }
    }

    // MARK: - Soft reply focus

    private func replyFocusOpacity(for messageId: String) -> Double {
        guard !isEditMode, !replyFocusIds.isEmpty else {
            return ChatUIConstants.ReplyFocus.focusedOpacity
        }
        if replyFocusIds.contains(messageId.lowercased()) {
            return ChatUIConstants.ReplyFocus.focusedOpacity
        }
        return ChatUIConstants.ReplyFocus.dimmedOpacity
    }

    private func setComposeReplyFocus(messageId: String) {
        replyFocusPeekTask?.cancel()
        replyFocusPeekTask = nil
        withAnimation(.easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration)) {
            replyFocusIds = [messageId.lowercased()]
        }
    }

    private func peekReplyChain(for message: TranscriptRow) {
        let childId = message.id.lowercased()
        let parentId = (message.replyToMessageId ?? "").lowercased()
        guard !parentId.isEmpty else { return }

        replyFocusPeekTask?.cancel()
        withAnimation(.easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration)) {
            replyFocusIds = [parentId, childId]
        }
        scrollManager.scrollTo(messageId: parentId, anchor: .center, animated: true)

        let holdParent = parentId
        replyFocusPeekTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ChatUIConstants.ReplyFocus.peekHoldNanoseconds)
            guard !Task.isCancelled else { return }
            if replyingTo?.id.lowercased() == holdParent { return }
            clearReplyFocus(animated: true)
        }
    }

    private func clearReplyFocus(animated: Bool) {
        replyFocusPeekTask?.cancel()
        replyFocusPeekTask = nil
        guard !replyFocusIds.isEmpty else { return }
        if animated {
            withAnimation(.easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration)) {
                replyFocusIds = []
            }
        } else {
            replyFocusIds = []
        }
    }

    // MARK: - Actions

    private func markChatAsRead() {
        let chatId = viewModel.conversation.chatId
        guard let unread = try? LocalRepositories.chats.chat(chatId)?.unreadCount, unread > 0 else { return }
        try? LocalRepositories.chats.setUnread(chatId, 0)
    }

    private func toggleMessageSelection(_ message: TranscriptRow) {
        if selectedMessages.contains(message.id) {
            selectedMessages.remove(message.id)
        } else {
            selectedMessages.insert(message.id)
        }
    }

    // MARK: - Forward

    private func startForward(_ rows: [TranscriptRow]) {
        forwarding = rows
        showingForwardPicker = true
    }

    /// The picked chat sends it: this one at once, any other when it opens.
    private func finishForward(to chat: ChatRecord) {
        ForwardDrafts.shared.hand(ForwardItem.content(of: forwarding), to: chat.id)
        forwarding = []
        withAnimation { selectedMessages.removeAll(); isEditMode = false }
        if chat.id != viewModel.conversation.chatId {
            chatsViewModel.chatToOpen = chat.id
        }
    }

    private func sendForwardedHere() async {
        let items = ForwardDrafts.shared.take(for: viewModel.conversation.chatId)
        guard !items.isEmpty else { return }
        let failures = await viewModel.forward(items)
        if !failures.isEmpty { forwardFailed = true }
    }

    private func deleteSelectedMessages() {
        guard !selectedMessages.isEmpty else { return }
        viewModel.deleteMessages(withIds: selectedMessages)
        withAnimation { selectedMessages.removeAll(); isEditMode = false }
    }

    /// Same gate as iOS `ChatView.attemptLoadOlderHistory` — see `ChatScrollManager.shouldLoadOlderHistory`.
    // MARK: - Transcript container wiring (shared type, see ChatTranscriptContainer)

    private func registerTranscriptProxy(_ proxy: ScrollViewProxy) {
        scrollManager.registerProxy(proxy)
        LocalNotificationManager.shared.clearBadge()
        // Same as iOS: only arm opening when a transcript is already present.
        // Empty → 0→N is handled by handleTranscriptCountChange.
        if !viewModel.entries.isEmpty {
            scrollManager.beginOpening()
        }
    }

    private func handleTranscriptGeometry(from _: ChatScrollGeometry, to metrics: ChatScrollGeometry) {
        // Same contract as iOS: record geometry only — never re-pin on height change
        // (that loop heated the phone: pin → rematerialize → new height → pin).
        scrollManager.updateScrollOffset(
            distanceFromBottom: metrics.distanceFromBottom,
            contentFits: metrics.contentFits,
            contentHeight: metrics.contentHeight,
            visibleMinY: metrics.visibleMinY
        )
        if metrics.width > 1, abs(metrics.width - containerWidth) > 0.5 {
            containerWidth = metrics.width
        }
        attemptLoadOlderHistory()
    }

    private func handleTranscriptScrollPhase(_ phase: ScrollPhase) {
        // Same contract as iOS — the decision lives in ChatScrollManager.
        scrollManager.noteScrollPhase(phase)
    }

    /// Infinite-scroll sentinel (same policy as iOS ChatView) — no manual button.
    /// Load gated by `ChatScrollManager.shouldLoadOlderHistory` (TODO 34).
    @ViewBuilder
    private var loadMoreSentinel: some View {
        if viewModel.hasMoreMessages && !filteredMessages.isEmpty {
            Group {
                if viewModel.isLoadingMore {
                    ProgressView()
                        .padding(.vertical, 8)
                } else {
                    Color.clear
                        .frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity)
            .id("loadMoreIndicator")
            .accessibilityHidden(true)
            .onAppear {
                attemptLoadOlderHistory()
            }
        }
    }

    @ViewBuilder
    private var transcriptRows: some View {
                ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, message in
                    VStack(spacing: 0) {
                        ObservedTranscriptRow(entry: message) { row in MessageBubble(
                            message: row,
                            isLastInGroup: message.isLastInGroup(at: index, in: filteredMessages),
                            isSelected: selectedMessages.contains(message.id),
                            isEditMode: isEditMode,
                            onRetry: { msg in viewModel.retryMessage(msg) },
                            onReply: { msg in
                                replyingTo = msg
                                replyQuoteText = nil
                                setComposeReplyFocus(messageId: msg.id)
                            },
                            onDelete: { msg in viewModel.deleteMessage(msg) },
                            onSelect: { msg in toggleMessageSelection(msg) },
                            onEnterSelectMode: nil,
                            onTapMedia: { msg, itemIndex in
                                galleryStartItem = GalleryStartItem(id: msg.id, itemIndex: itemIndex)
                            },
                            onEdit: { msg in viewModel.editingMessage = msg },
                            onReplyWithQuote: { msg, _ in quotingMessage = msg },
                            onJumpToReply: { msg in peekReplyChain(for: msg) },
                            onReact: { msg, emoji in
                                viewModel.sendReaction(msg, emoji: emoji)
                            },
                            onForward: { msg in startForward([msg]) }
                        ) }
                        .id(message.id)
                        .onAppear {
                            if index == filteredMessages.count - 1 {
                                scrollManager.noteLastMessageVisible(true, searchActive: isSearchActive)
                            }
                        }
                        .onDisappear {
                            if index == filteredMessages.count - 1 {
                                scrollManager.noteLastMessageVisible(false, searchActive: isSearchActive)
                            }
                        }
                        .opacity(replyFocusOpacity(for: message.id))
                        .animation(
                            .easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration),
                            value: replyFocusIds
                        )

                        if index < filteredMessages.count - 1 {
                            Spacer()
                                .frame(height: message.spacingAfterMessage(at: index, in: filteredMessages))
                        }
                    }
                }
    }

    private func attemptLoadOlderHistory() {
        guard scrollManager.shouldLoadOlderHistory(
            isSearchActive: isSearchActive,
            isLoadingMore: viewModel.isLoadingMore,
            hasMoreMessages: viewModel.hasMoreMessages
        ) else { return }
        viewModel.loadMoreMessages(trigger: .indicatorAppeared)
    }

    private func loadContactKTStatus() {
        if let contact = try? LocalRepositories.contacts.contact(peerId) {
            contactKTStatus = contact.ktStatus
            contactTrustAlert = contact.trustAlert
        }
    }

    private func hideKeyboard() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - Drag & Drop

    private func handleChatDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = PlatformImage(data: data) else { return }
                    DispatchQueue.main.async { chatDropImages.append(image) }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let imgData = try? Data(contentsOf: url)
                        DispatchQueue.main.async {
                            if let imgData, let image = PlatformImage(data: imgData) {
                                chatDropImages.append(image)
                            } else {
                                chatDropFileURLs.append(url)
                            }
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

/// Pushes the peer's live display name into the window title. Chat does not change when the
/// contact's profile does, so the name is read from `ContactsLive`, whose changes redraw it.
private struct DesktopChatWindowTitle: ViewModifier {
    var userId: String?
    let fallback: String

    func body(content: Content) -> some View {
        if let userId, !userId.isEmpty {
            content
                .navigationTitle(ContactsLive.shared.contact(userId)?.resolvedDisplayName
                    ?? DisplayNameGenerator.generate(from: userId))
        } else {
            content
                .navigationTitle(fallback)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Desktop Chat") {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    let user = PreviewHelpers.createSampleUser(context: context, username: "alice", displayName: "Alice")
    let chat = PreviewHelpers.createSampleChat(context: context, with: user)

    let _ = {
        _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Hey, how's the build going?")
        _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: true, text: "Compiling now, almost done")
        _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Nice, let me know when it's ready")
    }()

    DesktopChatView(conversation: Conversation(chatId: chat.id, peerId: user.id), context: context)
        .environment(\.managedObjectContext, context)
        .frame(width: 600, height: 500)
}
#endif
