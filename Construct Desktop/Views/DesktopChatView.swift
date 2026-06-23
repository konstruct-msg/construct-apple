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
    @State private var viewModel: ChatViewModel
    @State private var scrollManager = ChatScrollManager()
    private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State private var replyingTo: Message?
    @State private var replyQuoteText: String? = nil
    @State private var quotingMessage: Message? = nil
    @State private var showingUserProfile = false
    @State private var callManager = CallManager.shared

    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var isEditMode = false
    @State private var selectedMessages: Set<String> = []
    @State private var galleryStartItem: GalleryStartItem?

    @State private var chatDropImages: [PlatformImage] = []
    @State private var isChatDropTargeted = false

    @State private var floodGuard = IncomingFloodGuard.shared
    @State private var contactKTStatus: KTStatus = .unverified
    @State private var containerWidth: CGFloat = 800

    init(chat: Chat, context: NSManagedObjectContext) {
        _viewModel = State(wrappedValue: ChatViewModel(chat: chat, context: context))
    }

    var body: some View {
        ZStack() {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if viewModel.hasMoreMessages && !filteredMessages.isEmpty {
                            HStack {
                                Spacer()
                                if viewModel.isLoadingMore {
                                    ProgressView().padding()
                                } else {
                                    Button {
                                        viewModel.loadMoreMessages()
                                    } label: {
                                        Text(NSLocalizedString("load_older_messages", comment: ""))
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

                        ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { index, message in
                            VStack(spacing: 0) {
                                MessageBubble(
                                    message: message,
                                    isLastInGroup: message.isLastInGroup(at: index, in: filteredMessages),
                                    isSelected: selectedMessages.contains(message.id),
                                    isEditMode: isEditMode,
                                    onRetry: { msg in viewModel.retryMessage(msg) },
                                    onReply: { msg in
                                        replyingTo = msg
                                        replyQuoteText = nil
                                    },
                                    onDelete: { msg in viewModel.deleteMessage(msg) },
                                    onSelect: { msg in toggleMessageSelection(msg) },
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
                                    onEdit: { msg in viewModel.editingMessage = msg },
                                    onReplyWithQuote: { msg, _ in quotingMessage = msg }
                                )
                                .id(message.id)

                                if index < filteredMessages.count - 1 {
                                    Spacer()
                                        .frame(height: message.spacingAfterMessage(at: index, in: filteredMessages))
                                }
                            }
                        }
                        // Bottom anchor for scrollToBottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    // Padding so latest messages stay visible above the floating glass input,
                    // and top messages are not hidden under the glass nav bar.
                    // Reduced because nav is now flush (0 top padding) at the pane top.
                    .padding(.top, 70)
                    .padding(.bottom, 130)
                    .padding(.horizontal)
                }
                .background(Color.CT.bg) // base dark for the area under glass panels
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .environment(\.containerWidth, containerWidth)
                .onTapGesture { hideKeyboard() }
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
                .onChange(of: viewModel.messages.count) { _, _ in
                    if scrollManager.shouldScrollToBottom && !isSearchActive && !viewModel.messages.isEmpty {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(ChatViewConstants.MessageDelay.mediaRender))
                            if let last = filteredMessages.last {
                                scrollManager.scrollToBottom(messageId: last.id)
                            }
                        }
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
                        if let last = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: last.id)
                        }
                    }
                }
                .onChange(of: isSearchActive) { _, active in
                    if active {
                        if isEditMode { isEditMode = false; selectedMessages.removeAll() }
                    } else {
                        searchText = ""
                        scrollManager.shouldScrollToBottom = true
                        if let last = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: last.id)
                        }
                    }
                }
                .onChange(of: isEditMode) { _, editMode in
                    if editMode && isSearchActive { isSearchActive = false; searchText = "" }
                }
                .onChange(of: viewModel.editingMessage) { _, editMsg in
                    if let editMsg {
                        if let mc = parseMediaContent(from: editMsg.displayText) {
                            messageText = mc.caption
                        } else {
                            messageText = editMsg.displayText
                        }
                    }
                }
            }
        
        
            VStack(spacing: 10) {
                chatNavBar
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)   // flush or minimal top so the glass panel sits at the very top of the chat pane
                floodBurstBanner

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
                    UserProfileView(user: user, showMessageButton: false)
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
            .onAppear {
                guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
                markChatAsRead()
                viewModel.onViewAppear()
                loadContactKTStatus()
                if let contactId = viewModel.chat.otherUser?.id, !contactId.isEmpty {
                    _ = try? CryptoManager.shared.handleOrchestratorEvent(
                        .activeChatChanged(contactId: contactId, isActive: true),
                        tag: "chat_active_true"
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .contactKeyChanged)) { note in
                guard let changedId = note.userInfo?["userId"] as? String,
                      changedId == viewModel.chat.otherUser?.id else { return }
                loadContactKTStatus()
            }
            .onDisappear {
                guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
                if let contactId = viewModel.chat.otherUser?.id, !contactId.isEmpty {
                    _ = try? CryptoManager.shared.handleOrchestratorEvent(
                        .activeChatChanged(contactId: contactId, isActive: false),
                        tag: "chat_active_false"
                    )
                }
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
        .ignoresSafeArea(.container, edges: .top) // make glass nav flush to the very top edge of the NavigationSplitView detail
    }

    // MARK: - View Components

    @ViewBuilder
    private var floodBurstBanner: some View {
        let senderId = viewModel.chat.otherUser?.id ?? ""
        if floodGuard.suppressedSenders.contains(senderId) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
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
                    scrollManager.shouldScrollToBottom = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(ChatViewConstants.MessageDelay.scrollAfterSend))
                        if let last = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: last.id)
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
            if scrollManager.shouldShowScrollToBottomButton && !isEditMode {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        if let last = filteredMessages.last {
                            scrollManager.scrollToBottom(messageId: last.id)
                        }
                        scrollManager.shouldScrollToBottom = true
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "chevron.down.circle.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(Color.CT.accent, Color.CT.bg.opacity(0.85))
                        if viewModel.chat.unreadCount > 0 {
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

    // MARK: - Navigation Bar

    private var chatNavBar: some View {
        HStack(spacing: 10) {
            // No back button — navigation is controlled by NavigationSplitView sidebar

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

            ktBadge

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
                        Task {
                            await callManager.startOutgoingCall(
                                to: otherUser.id,
                                displayName: otherUser.resolvedDisplayName,
                                hasVideo: false
                            )
                        }
                    } label: {
                        Image(systemName: "phone")
                            .font(.system(size: CTLayout.navIconSizeLg, weight: .medium))
                            .foregroundColor(Color.CT.accent)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    withAnimation { isSearchActive.toggle(); if !isSearchActive { searchText = "" } }
                } label: {
                    Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                        .font(.system(size: CTLayout.navIconSize, weight: .medium))
                        .foregroundColor(Color.CT.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(Color.CT.bg.opacity(0.35)) // slight dark tint for terminal readability
        .clipShape(Capsule())
        .ctNoiseBorder() // thin noise border on top of glass
        .shadow(color: Color.black.opacity(0.2), radius: 8, y: 2)
    }

    @ViewBuilder private var ktBadge: some View {
        switch contactKTStatus {
        case .verified:
            Text("[✓]")
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.accent)
        case .keyChanged, .failed:
            Text("[!]")
                .font(CTFont.bold(11))
                .foregroundColor(Color.CT.danger)
        case .unverified:
            EmptyView()
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

    @ViewBuilder
    private func searchOverlay() -> some View {
        ChatSearchOverlayView(
            isSearchActive: $isSearchActive,
            searchText: $searchText,
            resultCount: filteredMessages.count
        )
    }

    // MARK: - Computed Properties

    private var filteredMessages: [Message] {
        let valid = viewModel.messages.filter { !$0.isDeleted && $0.managedObjectContext != nil }
        guard !searchText.isEmpty else { return valid }
        return valid.filter { $0.displayText.localizedCaseInsensitiveContains(searchText) }
    }

    private var mediaMessages: [Message] {
        viewModel.messages.filter {
            guard !$0.isDeleted, $0.managedObjectContext != nil else { return false }
            if let mc = parseMediaContent(from: $0.displayText) {
                return (mc.media["_placeholder"] as? Bool) != true
            }
            return false
        }
    }

    // MARK: - Actions

    private func markChatAsRead() {
        guard viewModel.chat.unreadCount > 0 else { return }
        viewModel.chat.unreadCount = 0
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
        viewModel.deleteMessages(withIds: selectedMessages)
        withAnimation { selectedMessages.removeAll(); isEditMode = false }
    }

    private func loadContactKTStatus() {
        guard let userId = viewModel.chat.otherUser?.id, !userId.isEmpty else { return }
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "id == %@", userId)
        req.fetchLimit = 1
        if let user = (try? viewContext.fetch(req))?.first {
            contactKTStatus = user.ktStatus
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

    DesktopChatView(chat: chat, context: context)
        .environment(\.managedObjectContext, context)
        .frame(width: 600, height: 500)
}
#endif
