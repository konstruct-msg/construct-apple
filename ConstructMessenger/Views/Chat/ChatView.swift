//
//  ChatView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatsViewModel.self) private var chatsViewModel
    @State private var viewModel: ChatViewModel
    @State private var scrollManager = ChatScrollManager()  // ✅ NEW: Isolated scroll management
    private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State private var replyingTo: Message?
    /// When non-nil, the user selected a partial quote from `replyingTo` for reply.
    @State private var replyQuoteText: String? = nil
    /// Message opened for "Quote & Reply" selection sheet.
    @State private var quotingMessage: Message? = nil
    @State private var showingUserProfile = false
    @State private var callManager: (any CallUIManaging)? = CallRuntimeProvider.makeUIManager()

    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var isEditMode = false
    @State private var selectedMessages: Set<String> = []
    @State private var galleryStartItem: GalleryStartItem?  // media gallery presenter

    // Drop target for drag-and-drop from Finder (macOS) over the whole chat area
    @State private var chatDropImages: [PlatformImage] = []
    @State private var isChatDropTargeted = false

    // Flood guard observer — updates when IncomingFloodGuard suppresses this chat's sender
    @ObservedObject private var floodGuard = IncomingFloodGuard.shared

    // Key Transparency status for the contact in this chat
    @State private var contactKTStatus: KTStatus = .unverified

    @State private var containerWidth: CGFloat = 390
    
    // ❌ REMOVED: Scroll-related @State variables (moved to ChatScrollManager)
    // - hasScrolledToBottom
    // - scrollProxy
    // - shouldScrollToBottom
    // - scrollOffset
    // - dragOffset

    init(chat: Chat, context: NSManagedObjectContext) {
        _viewModel = State(wrappedValue: ChatViewModel(chat: chat, context: context))
    }

    var body: some View {
        // Compute once per body pass to avoid repeated full-array filtering in render path.
        let renderedMessages = filteredMessages
        VStack(spacing: 0) {
            chatNavBar

            // Flood-burst banner — shown when this chat's sender is burst-suppressed
            floodBurstBanner
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Load more indicator at TOP of list (oldest messages)
                        if viewModel.hasMoreMessages && !renderedMessages.isEmpty {
                            HStack {
                                Spacer()
                                if viewModel.isLoadingMore {
                                    ProgressView()
                                        .padding()
                                } else {
                                    Button {
                                        viewModel.loadMoreMessages()
                                    } label: {
                                        Text(NSLocalizedString("load_older_messages", comment: "Load older messages button"))
                                            .font(CTFont.regular(12))
                                            .foregroundColor(Color.CT.accentDim)
                                            .padding(.vertical, 8)
                                    }
                                }
                                Spacer()
                            }
                            .id("loadMoreIndicator")
                            .onAppear {
                                if !viewModel.isLoadingMore && !isSearchActive {
                                    viewModel.loadMoreMessages()
                                }
                            }
                        }

                        // Messages in oldest-first order (ScrollView anchored to bottom via .defaultScrollAnchor)
                        ForEach(Array(renderedMessages.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 0) {
                                MessageBubble(
                                    message: message,
                                    isLastInGroup: message.isLastInGroup(at: index, in: renderedMessages),
                                    isSelected: selectedMessages.contains(message.id),
                                    isEditMode: isEditMode,
                                    onRetry: { msg in
                                        viewModel.retryMessage(msg)
                                    },
                                    onReply: { msg in
                                        replyingTo = msg
                                        replyQuoteText = nil
                                    },
                                    onDelete: { msg in
                                        viewModel.deleteMessage(msg)
                                    },
                                    onSelect: { msg in
                                        toggleMessageSelection(msg)
                                    },
                                    onEnterSelectMode: { msg in
                                        withAnimation {
                                            isEditMode = true
                                            isSearchActive = false
                                            searchText = ""
                                        }
                                        selectedMessages.insert(msg.id)
                                    },
                                    onTapMedia: { msg in
                                        galleryStartItem = GalleryStartItem(id: msg.id)
                                    },
                                    onEdit: { msg in
                                        viewModel.editingMessage = msg
                                    },
                                    onReplyWithQuote: { msg, _ in
                                        quotingMessage = msg
                                    }
                                )
                                .id(message.id)

                                // Add spacing after each message
                                if index < renderedMessages.count - 1 {
                                    Spacer()
                                        .frame(height: message.spacingAfterMessage(at: index, in: renderedMessages))
                                }
                            }
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .environment(\.containerWidth, containerWidth)
                .onTapGesture {
                    hideKeyboard()
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height - geo.contentSize.height
                } action: { _, offsetFromBottom in
                    scrollManager.updateScrollOffset(offsetFromBottom)
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.containerSize.width
                } action: { _, width in
                    if width > 0 { containerWidth = width }
                }
                .onAppear {
                    scrollManager.registerProxy(proxy)
                    LocalNotificationManager.shared.clearBadge()
                    scrollManager.hasScrolledToBottom = true
                }
                .onChange(of: viewModel.messages.count) { _, count in
                    if AppConstants.enableDebugLogging {
                        Log.info("ChatView: messages count changed to \(count)")
                    }

                    // Auto-scroll when new messages arrive — only if user is at the bottom.
                    // `shouldScrollToBottom` is automatically managed by ChatScrollManager
                    // based on scroll position, so this won't fight the user reading history.
                    if scrollManager.shouldScrollToBottom && !isSearchActive && !viewModel.messages.isEmpty {
                        let delay = ChatViewConstants.MessageDelay.mediaRender
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(delay))
                            if let lastMessage = filteredMessages.last {
                                scrollManager.scrollToBottom(messageId: lastMessage.id)
                            }
                        }
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    // ✅ Scroll to first search result
                    if !newValue.isEmpty, !filteredMessages.isEmpty, let firstMatch = filteredMessages.first {
                        let delay = ChatViewConstants.SearchDelay.scrollToResult
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(delay))
                            scrollManager.scrollTo(messageId: firstMatch.id, anchor: .center)
                        }
                    } else if newValue.isEmpty {
                        // When search is cleared, scroll back to bottom
                        scrollManager.shouldScrollToBottom = true
                        if let lastMessage = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: lastMessage.id)
                        }
                    }
                }
                .onChange(of: isSearchActive) { _, active in
                    if active {
                        // When search is activated, exit edit mode
                        if isEditMode {
                            isEditMode = false
                            selectedMessages.removeAll()
                        }
                    } else {
                        // When search is dismissed, scroll back to bottom
                        searchText = ""
                        scrollManager.shouldScrollToBottom = true
                        if let lastMessage = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: lastMessage.id)
                        }
                    }
                }
                .onChange(of: isEditMode) { _, editMode in
                    if editMode {
                        // When edit mode is activated, exit search
                        if isSearchActive {
                            isSearchActive = false
                            searchText = ""
                        }
                    }
                }
                .onChange(of: viewModel.editingMessage) { _, editMsg in
                    if let editMsg {
                        // For media messages pre-fill with caption, not the raw JSON payload
                        if let mc = parseMediaContent(from: editMsg.displayText) {
                            messageText = mc.caption
                        } else {
                            messageText = editMsg.displayText
                        }
                    }
                }
            }
            
            deleteButtonBar
            
            messageInputView
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        #endif
        // Edge-swipe-back is handled natively by interactivePopGestureRecognizer
        // (see InteractiveSwipeBack.swift) — no manual DragGesture needed.
        .onDrop(of: [.image, .fileURL], isTargeted: $isChatDropTargeted) { providers in
            handleChatDrop(providers: providers)
        }
        .overlay {
            ChatDropOverlayView(isVisible: isChatDropTargeted)
        }
        .overlay(alignment: .top) {
            ChatSearchOverlayView(
                isSearchActive: $isSearchActive,
                searchText: $searchText,
                resultCount: renderedMessages.count
            )
        }
        .sheet(isPresented: $showingUserProfile) {
            if let user = viewModel.chat.otherUser {
                UserProfileView(
                    user: user,
                    showMessageButton: false   // already inside this chat — no loop
                )
                .environment(\.managedObjectContext, viewContext)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(item: $quotingMessage) { msg in
            QuoteSelectionSheet(message: msg) { selectedQuote in
                replyingTo = msg
                replyQuoteText = selectedQuote
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear(perform: handleViewAppear)
        .onReceive(NotificationCenter.default.publisher(for: .contactKeyChanged), perform: handleContactKeyChanged)
        .onDisappear(perform: handleViewDisappear)
        #if os(iOS)
        .fullScreenCover(item: $galleryStartItem) { item in
                MediaGalleryViewer(
                    messages: mediaMessages(in: renderedMessages),
                    initialMessageId: item.id,
                    isPresented: Binding(
                    get: { galleryStartItem != nil },
                    set: { if !$0 { galleryStartItem = nil } }
                )
            )
        }
        #endif
        .alert(callManager?.lastError ?? "", isPresented: Binding(
            get: { callManager?.lastError != nil },
            set: { if !$0 { callManager?.clearLastError() } }
        )) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) {
                callManager?.clearLastError()
            }
        }
    }
    
    // MARK: - View Components

    /// Flood-burst warning banner — visible at the top of the chat when the sender
    /// is suppressed by IncomingFloodGuard.
    private var floodBurstBanner: some View {
        ChatFloodBannerView(
            isVisible: isFloodSenderSuppressed,
            onAllow: unsuppressFloodSender,
            onBlock: blockAndUnsuppressFloodSender
        )
    }

    private var floodSenderId: String {
        viewModel.chat.otherUser?.id ?? ""
    }

    private var isFloodSenderSuppressed: Bool {
        floodGuard.suppressedSenders.contains(floodSenderId)
    }

    private func unsuppressFloodSender() {
        IncomingFloodGuard.shared.unsuppress(senderId: floodSenderId)
    }

    private func blockAndUnsuppressFloodSender() {
        if let user = viewModel.chat.otherUser {
            user.isBlocked = true
            try? user.managedObjectContext?.save()
        }
        IncomingFloodGuard.shared.unsuppress(senderId: floodSenderId)
    }

    @ViewBuilder
    private var deleteButtonBar: some View {
        if isEditMode && !selectedMessages.isEmpty {
            ChatSelectionBarView(
                selectedCount: selectedMessages.count,
                onDelete: deleteSelectedMessages
            )
        }
    }
    
    private var messageInputView: some View {
        MessageInputView(
            text: $messageText,
            droppedImages: $chatDropImages,
            isSending: viewModel.isSending,
            replyingTo: replyingTo,
            quoteOverride: replyQuoteText,
            editingMessage: viewModel.editingMessage,
            onSend: { images, fileURLs in
                if let editMsg = viewModel.editingMessage {
                    viewModel.editMessage(editMsg, newText: messageText)
                    messageText = ""
                } else {
                    viewModel.sendMessage(
                        text: messageText,
                        images: images,
                        fileURLs: fileURLs,
                        replyTo: replyingTo,
                        replyToContentOverride: replyQuoteText
                    )
                    messageText = ""
                    DraftStore.shared.clear(for: viewModel.chat.id)
                    replyingTo = nil
                    replyQuoteText = nil

                    // ✅ Enable auto-scroll for new message
                    scrollManager.shouldScrollToBottom = true

                    // Scroll to bottom after sending (longer delay for media)
                    let sendDelay = ChatViewConstants.MessageDelay.scrollAfterSend
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(sendDelay))
                        if let lastMessage = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: lastMessage.id)
                        }
                    }
                }
            },
            onSendVoice: { url, duration, waveform in
                viewModel.sendVoiceMessage(url: url, duration: duration, waveform: waveform)
                scrollManager.shouldScrollToBottom = true
            },
            onCancelReply: {
                replyingTo = nil
                replyQuoteText = nil
            },
            onCancelEdit: {
                viewModel.editingMessage = nil
                messageText = ""
            }
        )
        .disabled(isEditMode)
        .overlay(alignment: .bottomTrailing) {
            // Scroll to bottom button (appears when scrolled far from newest)
            if scrollManager.shouldShowScrollToBottomButton && !isEditMode {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        if let lastMessage = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: lastMessage.id)
                        }
                        scrollManager.shouldScrollToBottom = true
                    }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 25))
                        .foregroundColor(Color.CT.accent)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 160) // Above message input
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrollManager.shouldShowScrollToBottomButton)
            }
        }
    }
    
    // MARK: - CT Navigation Bar

    private var chatNavBar: some View {
        ChatNavBarView(
            title: viewModel.chat.otherUser?.resolvedDisplayName ?? NSLocalizedString("chat", comment: ""),
            subtitle: navigationStatusSubtitle,
            contactKTStatus: contactKTStatus,
            isEditMode: isEditMode,
            canStartCall: canStartCall,
            isSearchActive: isSearchActive,
            onBack: { dismiss() },
            onOpenProfile: { showingUserProfile = true },
            onDoneEdit: {
                withAnimation {
                    isEditMode = false
                    selectedMessages.removeAll()
                }
            },
            onStartCall: startCall,
            onStartVideoCall: startVideoCall,
            onToggleSearch: {
                withAnimation {
                    isSearchActive.toggle()
                    if !isSearchActive { searchText = "" }
                }
            }
        )
    }

    /// Load KT status for the contact from Core Data.
    private func loadContactKTStatus() {
        guard let userId = viewModel.chat.otherUser?.id, !userId.isEmpty else { return }
        let ctx = viewContext
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", userId)
        req.fetchLimit = 1
        if let user = (try? ctx.fetch(req))?.first {
            contactKTStatus = user.ktStatus
        }
    }


    private var canStartCall: Bool {
        guard CallsFeature.isEnabled,
              let callManager,
              viewModel.chat.otherUser != nil,
              case .idle = callManager.state else { return false }
        return true
    }

    private func startCall() {
        startOutgoingCall(hasVideo: false)
    }

    private func startVideoCall() {
        startOutgoingCall(hasVideo: true)
    }

    private func startOutgoingCall(hasVideo: Bool) {
        guard let otherUser = viewModel.chat.otherUser else { return }
        guard let callManager else { return }
        Task {
            await callManager.startOutgoingCall(
                to: otherUser.id,
                displayName: otherUser.resolvedDisplayName,
                hasVideo: hasVideo
            )
        }
    }

    private var navigationStatusSubtitle: String? {
        connectionManager.navigationStatusSubtitle(
            isInitializingSession: viewModel.isInitializingSession
        )
    }

    // MARK: - Computed Properties

    private var filteredMessages: [Message] {
        // Guard against accessing deleted/faulted Core Data objects that the FRC
        // may not have removed from viewModel.messages before SwiftUI re-evaluates.
        let valid = viewModel.messages.filter { !$0.isDeleted && $0.managedObjectContext != nil }
        if searchText.isEmpty {
            return valid
        }
        return valid.filter { message in
            message.displayText.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// All media messages in display order. Upload placeholders are excluded.
    private func mediaMessages(in messages: [Message]) -> [Message] {
        messages.filter {
            guard let mc = parseMediaContent(from: $0.displayText) else { return false }
            return (mc.media["_placeholder"] as? Bool) != true
        }
    }

    // MARK: - Lifecycle

    private var isPreviewRuntime: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private func handleViewAppear() {
        guard !isPreviewRuntime else { return }
        // Restore an unsent draft saved when we last left this chat.
        if viewModel.editingMessage == nil, messageText.isEmpty {
            messageText = DraftStore.shared.draft(for: viewModel.chat.id)
        }
        markChatAsRead()
        viewModel.onViewAppear()
        loadContactKTStatus()
        setActiveChatState(isActive: true)
    }

    private func handleViewDisappear() {
        guard !isPreviewRuntime else { return }
        // Preserve a half-typed message across navigation. Skip while editing,
        // so the edit buffer never leaks into the new-message draft.
        if viewModel.editingMessage == nil {
            DraftStore.shared.save(messageText, for: viewModel.chat.id)
        }
        setActiveChatState(isActive: false)
    }

    private func handleContactKeyChanged(_ note: Notification) {
        guard let changedId = note.userInfo?["userId"] as? String,
              changedId == viewModel.chat.otherUser?.id else { return }
        loadContactKTStatus()
    }

    private func setActiveChatState(isActive: Bool) {
        guard let contactId = viewModel.chat.otherUser?.id, !contactId.isEmpty else { return }
        _ = try? CryptoManager.shared.handleOrchestratorEvent(
            .activeChatChanged(contactId: contactId, isActive: isActive),
            tag: isActive ? "chat_active_true" : "chat_active_false"
        )
    }

    // MARK: - Actions

    private func markChatAsRead() {
        let chat = viewModel.chat
        guard chat.unreadCount > 0 else { return }
        chat.unreadCount = 0
        try? viewContext.save()
    }

    private func toggleMessageSelection(_ message: Message) {
        if selectedMessages.contains(message.id) {
            selectedMessages.remove(message.id)
        } else {
            selectedMessages.insert(message.id)
        }
    }
    
    private func deleteSelectedMessages() {
        guard !selectedMessages.isEmpty else { return }
        
        let messageIds = selectedMessages
        viewModel.deleteMessages(withIds: messageIds)
        
        withAnimation {
            selectedMessages.removeAll()
            isEditMode = false
        }
    }
    
    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    // MARK: - Drag & Drop (macOS)

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
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    guard let imgData = try? Data(contentsOf: url),
                          let image = PlatformImage(data: imgData) else { return }
                    DispatchQueue.main.async { chatDropImages.append(image) }
                }
                handled = true
            }
        }
        return handled
    }
}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    // Create sample data
    let user = PreviewHelpers.createSampleUser(context: context, username: "alice", displayName: "Alice")
    let chat = PreviewHelpers.createSampleChat(context: context, with: user)

    // Add sample messages
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Hi! How are you?")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: true, text: "I'm good, thanks! So what about you?")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Great to hear!")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "I'm fine, just relaxing!")

    try? context.save()

    // SessionLifecycleController.shared is used internally — preview doesn't need DI
    let previewChatsViewModel = ChatsViewModel()
    return NavigationStack {
        ChatView(chat: chat, context: context)
            .environment(\.managedObjectContext, context)
            .environment(previewChatsViewModel)
    }
}
#endif
