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
    @ObservedObject private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State private var replyingTo: Message?
    @State private var showingUserProfile = false
    @State private var showResetSessionConfirm = false  // ← NEW
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var isEditMode = false
    @State private var selectedMessages: Set<String> = []
    @State private var galleryStartItem: GalleryStartItem?  // media gallery presenter

    // Drop target for drag-and-drop from Finder (macOS) over the whole chat area
    @State private var chatDropImages: [UIImage] = []
    @State private var isChatDropTargeted = false
    
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
            // ❌ REMOVED: statusBanner (moved to overlay)
            
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
                                            .font(FontStyle.caption)
                                            .foregroundColor(Color.AppText.accent)
                                            .padding(.vertical, Spacing.small)
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

                    // ✅ Auto-scroll when new messages arrive
                    if scrollManager.shouldScrollToBottom && !isSearchActive && !viewModel.messages.isEmpty {
                        // ✅ Longer delay for media messages to render
                        DispatchQueue.main.asyncAfter(deadline: .now() + ChatViewConstants.MessageDelay.mediaRender) {
                            if let lastMessage = filteredMessages.last {
                                scrollManager.scrollToBottom(messageId: lastMessage.id)
                            }
                        }
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    // ✅ Scroll to first search result
                    if !newValue.isEmpty, !filteredMessages.isEmpty, let firstMatch = filteredMessages.first {
                        DispatchQueue.main.asyncAfter(deadline: .now() + ChatViewConstants.SearchDelay.scrollToResult) {
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
            }
            
            deleteButtonBar
            
            messageInputView
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.visible, for: .navigationBar)  // ✅ FIX: Make navbar opaque
        .toolbarBackground(Color.AppBackground.primary, for: .navigationBar)  // ✅ FIX: Set background color
        .toolbar(content: toolbarContent)
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
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06).clipShape(RoundedRectangle(cornerRadius: 12)))
                    .overlay(
                        Label("Drop to attach", systemImage: "photo.badge.plus")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.accentColor)
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    )
                    .allowsHitTesting(false)
                    .padding(8)
            }
        }
        .overlay(alignment: .top, content: searchOverlay)
        .overlay(alignment: .top) {
            // ✅ Status banner as overlay (doesn't block messages)
            statusBanner
                .padding(.top, 0)  // Align to top under navbar
        }
        .sheet(isPresented: $showingUserProfile) {
            if let user = viewModel.chat.otherUser {
                UserProfileView(user: user)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
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
        .confirmationDialog(
            "Reset Session?",
            isPresented: $showResetSessionConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Session", role: .destructive) {
                Task {
                    guard let otherUserId = viewModel.chat.otherUser?.id else {
                        Log.error("❌ Cannot reset session: no other user", category: "ChatView")
                        return
                    }
                    
                    do {
                        let chatsVM = ChatsViewModel()
                        try await chatsVM.sendEndSession(
                            to: otherUserId,
                            reason: "user_requested"
                        )
                        Log.info("✅ Session reset requested by user", category: "ChatView")
                    } catch {
                        Log.error("❌ Failed to reset session: \(error)", category: "ChatView")
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-establish a new encrypted session. Messages in transit may be lost.")
        }
    }
    
    // MARK: - View Components
    
    @ViewBuilder
    private var statusBanner: some View {
        // Only show banner for actual error messages — network/session status moved to navigation subtitle
        if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
            statusBannerRow(text: errorMessage, color: .red, isLocalized: false)
        }
    }
    
    @ViewBuilder
    private func statusBannerRow(text: String, color: Color, showProgress: Bool = false, isLocalized: Bool = true) -> some View {
        HStack(spacing: 8) {
            if showProgress {
                ProgressView()
                    .scaleEffect(0.7)
            }
            // If text is already a full message (contains spaces or special chars), use it directly
            // Otherwise, try to localize it
            let displayText = isLocalized ? NSLocalizedString(text, comment: "") : text
            Text(displayText)
                .font(.caption)
                .foregroundColor(color)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(
            // ✅ Solid background with blur for overlay
            Color.AppBackground.primary
                .opacity(0.95)
        )
        .overlay(
            Rectangle()
                .fill(color.opacity(0.2))
        )
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    @ViewBuilder
    private var deleteButtonBar: some View {
        if isEditMode && !selectedMessages.isEmpty {
            HStack {
                Button(role: .destructive) {
                    deleteSelectedMessages()
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("delete_selected")
                    }
                    .foregroundColor(.red)
                }
                Spacer()
                Text("\(selectedMessages.count) \(selectedMessages.count == 1 ? "message_selected" : "messages_selected")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
        }
    }
    
    private var messageInputView: some View {
        MessageInputView(
            text: $messageText,
            droppedImages: $chatDropImages,
            isSending: viewModel.isSending,
            replyingTo: replyingTo,
            onSend: { images in
                viewModel.sendMessage(text: messageText, images: images, replyTo: replyingTo)
                messageText = ""
                replyingTo = nil
                
                // ✅ Enable auto-scroll for new message
                scrollManager.shouldScrollToBottom = true
                
                // ✅ FIX: Scroll to bottom after sending (longer delay for media)
                DispatchQueue.main.asyncAfter(deadline: .now() + ChatViewConstants.MessageDelay.scrollAfterSend) {
                    if let lastMessage = filteredMessages.last {
                        scrollManager.scrollToBottom(messageId: lastMessage.id)
                    }
                }
            },
            onCancelReply: {
                replyingTo = nil
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
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text(NSLocalizedString("new_messages", comment: "Scroll to new messages"))
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(Color.AppBackground.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                    )
                }
                .padding(.trailing, 16)
                .padding(.bottom, 80) // Above message input
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrollManager.shouldShowScrollToBottomButton)
            }
        }
    }
    
    @ToolbarContentBuilder
    private func toolbarContent() -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                showingUserProfile = true
            } label: {
                VStack(spacing: 1) {
                    Text(viewModel.chat.otherUser?.displayName ?? NSLocalizedString("chat", comment: "Default chat title"))
                        .font(.headline)
                        .foregroundColor(.primary)
                    if let subtitle = navigationStatusSubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: navigationStatusSubtitle)
            }
        }

        // Split into separate ToolbarItems to avoid NSToolbarItemGroup selectionMode warnings on macOS
        if !isEditMode {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        isSearchActive.toggle()
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    Button(role: .destructive) {
                        showResetSessionConfirm = true
                    } label: {
                        Label("Reset Session", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(Color.blue)
                }
            }
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation {
                        isSearchActive.toggle()
                        if !isSearchActive { searchText = "" }
                    }
                } label: {
                    Image(systemName: isSearchActive ? "xmark.circle.fill" : "magnifyingglass")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation {
                        isEditMode = false
                        selectedMessages.removeAll()
                    }
                } label: {
                    Text("done")
                }
            }
        }
    }  // end toolbarContent()

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
                HStack(spacing: 12) {
                    TextField("search_messages", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    Button {
                        withAnimation {
                            isSearchActive = false
                            searchText = ""
                        }
                    } label: {
                        Text("cancel")
                    }
                }
                .padding()
                .background(Color.AppBackground.primary.shadow(color: .black.opacity(0.1), radius: 2, y: 1))
                Spacer()
            }
        }
    }

    // MARK: - Computed Properties
    
    private var filteredMessages: [Message] {
        if searchText.isEmpty {
            return viewModel.messages // oldest-first from FRC; ScrollView anchored to bottom
        }
        return viewModel.messages.filter { message in
            message.decryptedContent?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    /// All media messages in this chat, in display order. Used by the gallery viewer.
    private var mediaMessages: [Message] {
        viewModel.messages.filter { parseMediaContent(from: $0.decryptedContent) != nil }
    }

    // MARK: - Actions
    
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
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - Drag & Drop (macOS)

    private func handleChatDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = UIImage(data: data) else { return }
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
                          let image = UIImage(data: imgData) else { return }
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
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: true, text: "I'm good, thanks!")
    _ = PreviewHelpers.createSampleMessage(context: context, chat: chat, isSentByMe: false, text: "Great to hear!")

    try? context.save()

    return NavigationStack {
        ChatView(chat: chat, context: context)
            .environment(\.managedObjectContext, context)
    }
}
#endif

