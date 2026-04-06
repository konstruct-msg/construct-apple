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
    @State private var viewModel: ChatViewModel  // ✅ FIX: State persists across view updates
    @State private var scrollManager = ChatScrollManager()  // ✅ NEW: Isolated scroll management
    private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State private var replyingTo: Message?
    /// When non-nil, the user selected a partial quote from `replyingTo` for reply.
    @State private var replyQuoteText: String? = nil
    /// Message opened for "Quote & Reply" selection sheet.
    @State private var quotingMessage: Message? = nil
    @State private var showingUserProfile = false
    @State private var callManager = CallManager.shared

    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var isEditMode = false
    @State private var selectedMessages: Set<String> = []
    @State private var galleryStartItem: GalleryStartItem?  // media gallery presenter

    // Drop target for drag-and-drop from Finder (macOS) over the whole chat area
    @State private var chatDropImages: [PlatformImage] = []
    @State private var isChatDropTargeted = false

    // Flood guard observer — updates when IncomingFloodGuard suppresses this chat's sender
    @State private var floodGuard = IncomingFloodGuard.shared
    
    // ✅ Swipe-to-dismiss gesture state (not scroll-related)
    @GestureState private var dragState: CGFloat = 0
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
        VStack(spacing: 0) {
            chatNavBar

            // Flood-burst banner — shown when this chat's sender is burst-suppressed
            floodBurstBanner
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Load more indicator at TOP of list (oldest messages)
                        if viewModel.hasMoreMessages && !filteredMessages.isEmpty {
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
                        ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 0) {
                                MessageBubble(
                                    message: message,
                                    isLastInGroup: message.isLastInGroup(at: index, in: filteredMessages),
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
                                if index < filteredMessages.count - 1 {
                                    Spacer()
                                        .frame(height: message.spacingAfterMessage(at: index, in: filteredMessages))
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
                        print("ChatView: messages count changed to \(count)")
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
                        if let mc = parseMediaContent(from: editMsg.decryptedContent) {
                            messageText = mc.caption
                        } else {
                            messageText = editMsg.decryptedContent ?? ""
                        }
                    }
                }
            }
            
            deleteButtonBar
            
            messageInputView
        }
        // macOS: give the VStack deterministic size so NavigationSplitView's
        // NSSplitView doesn't enter an infinite constraint-update loop when
        // the TextField(axis:) resizes inside an NSHostingView.
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .gesture(
            DragGesture(minimumDistance: 10)
                .updating($dragState) { value, state, _ in
                    // Only allow swipe from left edge (right swipe)
                    if value.startLocation.x < 20 && value.translation.width > 0 {
                        state = min(value.translation.width, containerWidth * ChatViewConstants.Gesture.maxDragRatio)
                    }
                }
                .onEnded { value in
                    // If swiped more than threshold, dismiss
                    let threshold = max(
                        ChatViewConstants.Gesture.dismissThreshold,
                        containerWidth * ChatViewConstants.Gesture.dismissThresholdRatio
                    )
                    if value.translation.width > threshold && value.startLocation.x < 20 {
                        withAnimation(.spring(
                            response: ChatViewConstants.Gesture.dismissSpringResponse,
                            dampingFraction: ChatViewConstants.Gesture.dismissSpringDamping
                        )) {
                            dismiss()
                        }
                    }
                }
        )
        .offset(x: dragState)
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
                            .font(CTFont.regular(16))
                            .foregroundColor(Color.CT.accent)
                            .padding(16)
                            .background(Color.CT.bgMsg)
                            .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4), lineWidth: 1))
                    )
                    .allowsHitTesting(false)
                    .padding(8)
            }
        }
        .overlay(alignment: .top, content: searchOverlay)
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
        .onAppear {
            markChatAsRead()
            viewModel.onViewAppear()
        }
        #if os(iOS)
        .fullScreenCover(item: $galleryStartItem) { item in
            MediaGalleryViewer(
                messages: mediaMessages,
                initialMessageId: item.id,
                isPresented: Binding(
                    get: { galleryStartItem != nil },
                    set: { if !$0 { galleryStartItem = nil } }
                )
            )
        }
        #else
        .sheet(item: $galleryStartItem) { item in
            MediaGalleryViewer(
                messages: mediaMessages,
                initialMessageId: item.id,
                isPresented: Binding(
                    get: { galleryStartItem != nil },
                    set: { if !$0 { galleryStartItem = nil } }
                )
            )
        }
        #endif
    }
    
    // MARK: - View Components

    /// Flood-burst warning banner — visible at the top of the chat when the sender
    /// is suppressed by IncomingFloodGuard.
    @ViewBuilder
    private var floodBurstBanner: some View {
        let senderId = viewModel.chat.otherUser?.id ?? ""
        if floodGuard.suppressedSenders.contains(senderId) {
            HStack(spacing: 10) {
                Text("[!]")
                    .font(CTFont.regular(16))
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
                    Text("[allow →]")
                        .font(CTFont.regular(12))
                        .foregroundStyle(.orange)
                }

                Button {
                    // Delegate to existing block flow
                    if let user = viewModel.chat.otherUser {
                        user.isBlocked = true
                        try? user.managedObjectContext?.save()
                    }
                    IncomingFloodGuard.shared.unsuppress(senderId: senderId)
                } label: {
                    Text("[block]")
                        .font(CTFont.regular(12))
                        .foregroundStyle(Color.CT.danger)
                }
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
                    Text("[\(NSLocalizedString("delete_selected", comment: "")) →]")
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger)
                }
                Spacer()
                Text("\(selectedMessages.count) \(selectedMessages.count == 1 ? "message_selected" : "messages_selected")")
                    .font(CTFont.regular(12))
                    .foregroundStyle(Color.CT.textDim)
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
            // ✅ Scroll to bottom button (appears when scrolled far from newest)
            if scrollManager.shouldShowScrollToBottomButton && !isEditMode {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        if let lastMessage = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: lastMessage.id)
                        }
                        scrollManager.shouldScrollToBottom = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("↓")
                            .font(CTFont.bold(14))
                        Text(viewModel.chat.unreadCount > 0
                             ? NSLocalizedString("new_messages", comment: "New messages below")
                             : NSLocalizedString("scroll_to_bottom", comment: "Scroll back to latest messages"))
                            .font(CTFont.regular(13))
                    }
                    .foregroundColor(Color.CT.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Rectangle()
                            .fill(Color.CT.bgMsg)
                            .overlay(Rectangle().strokeBorder(Color.CT.accent.opacity(0.5), lineWidth: 1))
                    )
                }
                .padding(.trailing, 16)
                .padding(.bottom, 80) // Above message input
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrollManager.shouldShowScrollToBottomButton)
            }
        }
    }
    
    // MARK: - CT Navigation Bar

    private var chatNavBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Text(CTSymbol.back)
                    .font(CTFont.bold(14))
                    .foregroundColor(Color.CT.accent)
            }

            Button { showingUserProfile = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text((viewModel.chat.otherUser?.resolvedDisplayName ?? NSLocalizedString("chat", comment: "")).uppercased())
                        .font(CTFont.bold(13))
                        .foregroundColor(Color.CT.text)
                    if let subtitle = navigationStatusSubtitle {
                        Text(subtitle)
                            .font(CTFont.regular(10))
                            .foregroundColor(Color.CT.accentDim)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: navigationStatusSubtitle)
            }
            .buttonStyle(.plain)

            Spacer()

            if isEditMode {
                Button {
                    withAnimation { isEditMode = false; selectedMessages.removeAll() }
                } label: {
                    Text("[done]")
                        .font(CTFont.bold(13))
                        .foregroundColor(Color.CT.accent)
                }
            } else {
                if CallsFeature.isEnabled, let otherUser = viewModel.chat.otherUser,
                   case .idle = callManager.state {
                    Button {
                        Task { await callManager.startOutgoingCall(
                            to: otherUser.id,
                            displayName: otherUser.resolvedDisplayName,
                            hasVideo: false
                        ) }
                    } label: {
                        Text(CTSymbol.tabCalls)
                            .font(CTFont.bold(14))
                            .foregroundColor(Color.CT.accent)
                    }
                }
                Button {
                    withAnimation { isSearchActive.toggle(); if !isSearchActive { searchText = "" } }
                } label: {
                    Text(isSearchActive ? CTSymbol.close : CTSymbol.search)
                        .font(CTFont.bold(14))
                        .foregroundColor(Color.CT.accent)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .ctBorderBottom()
    }


    /// Returns a subtle subtitle for the navigation bar when connection or session state requires attention.
    /// Returns nil when everything is healthy (no subtitle shown).
    private var navigationStatusSubtitle: String? {
        // Only show "Encrypting..." while actively establishing a session (user tapped Send).
        // Absence of a session before first send is normal — don't show a misleading subtitle.
        if viewModel.isInitializingSession {
            return NSLocalizedString("status_encrypting", comment: "")
        } else if connectionManager.connectionStatus == .connecting {
            return NSLocalizedString("status_connecting", comment: "")
        } else if !connectionManager.isConnected {
            return NSLocalizedString("status_no_connection", comment: "")
        }
        return nil
    }
    
    @ViewBuilder
    private func searchOverlay() -> some View {
        if isSearchActive {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(">")
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.accent)

                    TextField("search_messages", text: $searchText)
                        .font(CTFont.regular(14))
                        .foregroundStyle(Color.CT.text)
                        .tint(Color.CT.accent)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .submitLabel(.search)
                        #endif
                        .autocorrectionDisabled()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.CT.bgMsg)
                        .overlay(Rectangle().stroke(Color.CT.accent.opacity(0.4)))

                    Button {
                        withAnimation {
                            isSearchActive = false
                            searchText = ""
                        }
                    } label: {
                        Text("[x]")
                            .font(CTFont.regular(14))
                            .foregroundStyle(Color.CT.accentDim)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.CT.bg)

                if !searchText.isEmpty {
                    HStack {
                        Text("[\(filteredMessages.count) results]")
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .background(Color.CT.bg)
                }

                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.CT.accent.opacity(0.3))

                Spacer()
            }
        }
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
            message.decryptedContent?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    /// All media messages in this chat, in display order. Used by the gallery viewer.
    /// Upload placeholders (with `_placeholder: true`) are excluded — they have no real URL.
    private var mediaMessages: [Message] {
        viewModel.messages.filter {
            guard !$0.isDeleted, $0.managedObjectContext != nil else { return false }
            if let mc = parseMediaContent(from: $0.decryptedContent) {
                return (mc.media["_placeholder"] as? Bool) != true
            }
            return false
        }
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

    // ✅ REMOVED: Message grouping logic moved to Message+Grouping.swift extension
    
    /// Hide keyboard
    private func hideKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #else
        NSApp.keyWindow?.makeFirstResponder(nil)
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

    try? context.save()

    return NavigationStack {
        ChatView(chat: chat, context: context)
            .environment(\.managedObjectContext, context)
    }
}
#endif

