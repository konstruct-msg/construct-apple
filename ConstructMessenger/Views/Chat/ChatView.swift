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
    @Environment(\.scenePhase) private var scenePhase
    /// Between this chat's appear and disappear — not covered by a pushed profile or the like.
    @State private var isOnScreen = false
    /// Lazy holder — SwiftUI re-runs View.init on parent re-render; we must not
    /// allocate ChatViewModel there or discarded copies spam deinit / waste work.
    @State private var lazyViewModel: LazyChatViewModel
    var viewModel: ChatViewModel { lazyViewModel.value }
    var peerId: String { viewModel.conversation.peerId }
    private var peerName: String {
        ContactsLive.shared.contact(peerId)?.resolvedDisplayName ?? DisplayNameGenerator.generate(from: peerId)
    }
    /// Whoever owns the scroll position on this path. Chosen once, in `init`.
    ///
    /// Sampling the flag in `body` would let a mid-session flip put two owners on screen, which is
    /// build 586: two `ChatScrollManager`s on one NotificationCenter, each arming a pin series
    /// against the other. The Diagnostics toggle therefore lands on the next push of a chat.
    @State var viewport: any TranscriptViewportOwning
    /// Whether this view was built on the owned-inset path. Read from `viewport`'s type would be a
    /// second carrier of the same fact; this one is written once beside it.
    let usesOwnedInset: Bool
    private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State var replyingTo: TranscriptRow?
    /// When non-nil, the user selected a partial quote from `replyingTo` for reply.
    @State var replyQuoteText: String? = nil
    /// Message opened for "Quote & Reply" selection sheet.
    @State var quotingMessage: TranscriptRow? = nil
    /// Soft reply focus — lowercased message ids that stay full-opacity; others dim.
    /// Empty = idle chat (no visual change). See ``ChatUIConstants.ReplyFocus``.
    @State var replyFocusIds: Set<String> = []
    @State var replyFocusPeekTask: Task<Void, Never>?
    @State var showingUserProfile = false
    /// The top safe area — status bar and the system bar. The UIKit transcript lays out under the
    /// bar and needs it as padding; a SwiftUI scroll view does that itself.
    @State var topBarInset: CGFloat = 0
    @State private var callManager: (any CallUIManaging)? = CallRuntimeProvider.makeUIManager()

    @State var searchText = ""
    @State var isSearchActive = false
    @State var isEditMode = false
    @State var selectedMessages: Set<String> = []
    /// What the forward picker on screen will send.
    @State var forwarding: [TranscriptRow] = []
    @State var showingForwardPicker = false
    @State var forwardFailed = false
    @Environment(ChatsViewModel.self) var chatsViewModel
    @State var galleryStartItem: GalleryStartItem?  // media gallery presenter

    // Drop target for drag-and-drop from Finder (macOS) over the whole chat area
    @State private var chatDropImages: [PlatformImage] = []
    @State private var isChatDropTargeted = false

    // Flood guard observer — updates when IncomingFloodGuard suppresses this chat's sender
    @ObservedObject private var floodGuard = IncomingFloodGuard.shared

    // Key Transparency status for the contact in this chat
    @State var contactKTStatus: KTStatus = .unverified
    @State var contactTrustAlert: ContactTrustAlert?
    /// True when the session with this contact was established via a degraded (stale-SPK) init.
    @State private var isSessionAtRisk = false
    /// Safety Numbers sheet after key-change "Verify".
    @State var showingSafetyNumbers = false

    @State var containerWidth: CGFloat = ChatUIConstants.Bubble.defaultContainerWidth
    /// Current height of the bottom composer (safeAreaInset). Tracked so we can re-pin the
    /// scroll when it changes — see the composer's `.onGeometryChange` below.
    @State var composerHeight: CGFloat = 0
    /// Bottom safe area, and the scroll view's own height. Held because the keyboard moves both
    /// while leaving the composer's height alone, and a latch blind to that reads a keyboard
    /// animation as a settled layout.
    ///
    /// Both are now written from the geometry tick, which is where they are measured. They exist as
    /// state only because the composer's own report — which cannot see the scroll view — needs the
    /// two numbers it does not carry. `bottomSafeAreaInset` was declared here and never assigned
    /// at all until 2026-08-21.
    @State var bottomSafeAreaInset: CGFloat = 0
    @State var transcriptContainerHeight: CGFloat = 0
    /// Where the held row sits in content coordinates, reported by that row alone, tagged with
    /// which row reported it.
    ///
    /// Only one row carries the measurement, and only while somebody is reading history — this is
    /// the exact signal `TranscriptOffsetPolicy` needs and the reason the hold rule works for a
    /// prepend *and* for a photo finishing its decode above the reader. Comparing content heights
    /// cannot tell those from growth below the reader.
    ///
    /// The tag is what makes it safe to leave lying around: nothing clears this when a history
    /// visit ends, so without it the next visit's first sample would be differenced against the
    /// previous visit's last one — two different rows, and a shift that measures nothing.
    @State var anchorSample: TranscriptRowSample?
    /// Where the row a guest scroll is heading for sits. Same reporter as the anchor, installed on
    /// a different row and for a different question: the anchor's *movement* is the reading
    /// position, this row's *position* is the destination.
    @State var scrollTargetSample: TranscriptRowSample?
    /// Last geometry sample, so the new path can hand `handleTranscriptGeometry` an `old` value
    /// the way the container's `(old, new)` callback does.
    ///
    /// A reference box rather than `@State`, and that is the point. It was `@State`, written from
    /// `scrollViewDidScroll` — every frame of every drag. Each write invalidated this body, which
    /// reassigns `host.rootView` in `updateUIView`, which rebuilds all thirty rows of the eager
    /// stack, which re-measures to a slightly different height, which lands the offset again and
    /// emits another sample. That loop is idempotent in a short chat, where the height is stable;
    /// in a long one it is the flicker. What it was buying is the `old` argument of a log that is
    /// off by default.
    @State var geometryHistory = TranscriptGeometryHistory()
    // "Is the layout settled enough to read geometry as intent" lives with the owner
    // (`layoutPrimed`). It was a `@State` here and was armed from the wrong evidence.

    enum Layout {
        static let composerHorizontalPadding = ChatUIConstants.Shell.composerHorizontalPadding
        static let composerBottomPadding = ChatUIConstants.Shell.composerBottomPadding
        static let messageBottomClearance = ChatUIConstants.Shell.messageBottomClearance
        /// Same cutoff as ``ChatScrollManager/heightRepinThreshold`` — layout noise, not a pin trigger.
        static let geometryLogThreshold = ChatScrollManager.heightRepinThreshold
    }

    /// Probe log for viewport moves. Gated by ``ChatScrollManager.verboseGeometryLogging`` —
    /// default off so thermal/export sessions stay readable. Requires a real move/growth even
    /// during opening (the old `|| isOpening` branch logged every layout pass).
    func logScrollGeometryIfChanged(from old: ChatScrollGeometry, to new: ChatScrollGeometry) {
        guard ChatScrollManager.verboseGeometryLogging else { return }
        let moved = abs(new.visibleMinY - old.visibleMinY) >= Layout.geometryLogThreshold
        let grew = abs(new.contentHeight - old.contentHeight) >= Layout.geometryLogThreshold
        guard moved || grew else { return }
        ChatScrollManager.logGeometry(
            "SCROLL_GEO content=\(Int(new.contentHeight))pt viewport=[\(Int(new.visibleMinY))…\(Int(new.visibleMinY + (new.contentHeight - new.distanceFromBottom - new.visibleMinY)))] fromBottom=\(Int(new.distanceFromBottom)) msgs=\(viewModel.entries.count) \(viewport.stateDescription)"
        )
    }

    init(conversation: Conversation, context: NSManagedObjectContext) {
        _lazyViewModel = State(wrappedValue: LazyChatViewModel {
            ChatViewModel(conversation: conversation, context: context)
        })
        let owned = ChatViewportConfiguration.ownedInsetStackEnabled
        self.usesOwnedInset = owned
        // One owner is constructed, never both: the legacy one subscribes to NotificationCenter in
        // its initialiser, and a second subscriber is what build 586 was.
        _viewport = State(wrappedValue: owned ? ChatViewport() : ChatScrollManager())
        // Which owner ran is otherwise only inferable from the *absence* of `PIN arm` lines, and
        // inferring a path from silence is how three flag-flip attempts were misread as working.
        Log.info("CHAT_VIEWPORT: owner=\(owned ? "ChatViewport (UIKit scroll)" : "ChatScrollManager (SwiftUI scroll)")", category: "ChatView")
    }

    var body: some View {
        // Compute once per body pass to avoid repeated full-array filtering in render path.
        let renderedMessages = filteredMessages

        // The transcript under the system bar's glass and the floating composer.
        ZStack {
            // Full-bleed chat background so the floating input capsule sits over a continuous
            // surface — without this the ScrollView's own background stops at the safe area and
            // the bottom safe-area band renders with the window background, reading as an opaque
            // strip under the capsule.
            Color.CT.bg.ignoresSafeArea()

            // Message list — base layer, scrolls under the bar and the composer
            transcript(renderedMessages)
                .onChange(of: viewModel.entries.count) { oldCount, count in
                    if AppConstants.enableDebugLogging {
                        Log.info("ChatView: messages count changed to \(count)")
                    }
                    // One entry for every transcript length change; the decision is the
                    // owner's (`countChangeAction`).
                    viewport.handleTranscriptCountChange(
                        oldCount: oldCount,
                        newCount: count,
                        searchActive: isSearchActive
                    )
                }
                // Every sentinel appear before the landing is refused, so a short window that
                // still fits must be allowed to fill once the tail is down — without waiting for a
                // scroll that may never come.
                .onChange(of: viewport.layoutPrimed) { _, primed in
                    if primed {
                        attemptLoadOlderHistory()
                        // Opened from the now-playing banner: its message, once the tail is down.
                        if let focus = ChatOnScreen.shared.takeFocus(in: viewModel.conversation.chatId) {
                            jumpToMessage(focus)
                        }
                    }
                }
                // The now-playing banner tapped in this chat: its message, wherever history is.
                .onChange(of: ChatOnScreen.shared.jump) { _, _ in
                    if let id = ChatOnScreen.shared.takeJump(in: viewModel.conversation.chatId) {
                        jumpToMessage(id)
                    }
                }
                .onChange(of: viewModel.voicePlaybackScrollTarget) { _, target in
                    // Continuous voice playback advanced — bring the now-playing message
                    // into view (centered), then clear the target so a later replay re-scrolls.
                    guard let target else { return }
                    jumpToMessage(target)
                    viewModel.voicePlaybackScrollTarget = nil
                }
                .onChange(of: searchText) { _, newValue in
                    // ✅ Scroll to first search result
                    if !newValue.isEmpty, !filteredMessages.isEmpty, let firstMatch = filteredMessages.first {
                        let delay = ChatViewConstants.SearchDelay.scrollToResult
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(delay))
                            jumpToMessage(firstMatch.id)
                        }
                    } else if newValue.isEmpty {
                        // Search cleared: the one place besides the jump control that is
                        // allowed to take the reader back to the newest message.
                        viewport.followExplicitly()
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
                        // Search dismissed: same explicit return as clearing the query.
                        searchText = ""
                        viewport.followExplicitly()
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
                        // A media message edits its caption.
                        messageText = editMsg.readableText
                    }
                }

            // Search and the banners, under the system bar.
            VStack(spacing: ChatUIConstants.Shell.floatingChromeSpacing) {
                if isSearchActive {
                    ChatSearchChromeView(
                        searchText: $searchText,
                        resultCount: renderedMessages.count,
                        onClose: {
                            withAnimation {
                                isSearchActive = false
                            }
                        }
                    )
                    .padding(.horizontal, ChatUIConstants.Shell.floatingChromeHorizontal)
                }

                floodBurstBanner

                keyChangeBanner

                atRiskBanner

                deleteButtonBar

                Spacer(minLength: 0)
            }
            .padding(.top, callBarInset)
            .frame(maxHeight: .infinity, alignment: .top)

        }
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { topBarInset = $0 }
        .toolbar { chatToolbar }
        .inlineNavTitle()
        #if os(iOS)
        .hidesTabBar()
        .softTopScrollEdge()
        #endif
        .modifier(ComposerPlacement(usesOverlay: usesOwnedInset) { composer })
        .onDrop(of: [.image, .fileURL], isTargeted: $isChatDropTargeted) { providers in
            handleChatDrop(providers: providers)
        }
        .overlay {
            ChatDropOverlayView(isVisible: isChatDropTargeted)
        }
        .sheet(isPresented: $showingUserProfile) {
            UserProfileView(
                userId: peerId,
                showMessageButton: false   // already inside this chat — no loop
            )
            .sheetNavigation()
            .environment(\.managedObjectContext, viewContext)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingForwardPicker) {
            ForwardPickerView(onPick: finishForward(to:))
                .sheetNavigation()
        }
        .task(id: ForwardDrafts.shared.pending[viewModel.conversation.chatId]?.count ?? 0) {
            await sendForwardedHere()
        }
        .alert(NSLocalizedString("forward_failed", comment: ""), isPresented: $forwardFailed) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
        }
        .sheet(isPresented: $showingSafetyNumbers) {
            SafetyNumberView(
                theirDeviceIds: KeyChangeUX.safetyDeviceIds(ofContact: peerId),
                theirDisplayName: peerName
            )
            .sheetNavigation()
        }
        .sheet(item: $quotingMessage) { msg in
            QuoteSelectionSheet(message: msg) { selectedQuote in
                replyingTo = msg
                replyQuoteText = selectedQuote
                setComposeReplyFocus(messageId: msg.id)
            }
            .sheetNavigation()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear(perform: handleViewAppear)
        .onReceive(NotificationCenter.default.publisher(for: .contactKeyChanged), perform: handleContactKeyChanged)
        // Session init/degrade happens during send; re-read the at-risk flag when it settles.
        .onChange(of: viewModel.isInitializingSession) { _, _ in refreshSessionAtRiskState() }
        // Posted when an at-risk session is auto-upgraded — refresh the banner so it disappears.
        .onReceive(NotificationCenter.default.publisher(for: .sessionAtRiskChanged)) { note in
            if (note.userInfo?["userId"] as? String) == peerId {
                refreshSessionAtRiskState()
            }
        }
        .onDisappear(perform: handleViewDisappear)
        // A video note expanding in place grows downward; bring the whole of it into view.
        .onChange(of: VideoNotePlayback.shared.expanded) { _, key in
            guard let key else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(ChatUIConstants.VideoNote.expandDuration))
                guard VideoNotePlayback.shared.expanded == key else { return }
                viewport.scrollTo(messageId: key.messageId, anchor: .center, animated: true)
            }
        }
        // Messages that arrive while the chat is open behind a locked or backgrounded app are
        // counted unread, rightly. Coming back shows them in this chat, and appear does not fire
        // again — so without this the count outlived the reading and showed on the list.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isOnScreen { markChatAsRead() }
        }
        #if os(iOS)
        .fullScreenCover(item: $galleryStartItem) { item in
                MediaGalleryViewer(
                    messages: mediaMessages(in: renderedMessages),
                    initialMessageId: item.messageId,
                    initialItemIndex: item.itemIndex,
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

    /// Informational banner shown when the session was established via degraded (stale-SPK) init.
    private var atRiskBanner: some View {
        ChatAtRiskBannerView(isVisible: isSessionAtRisk)
    }

    /// First-class trust event: identity key changed or KT verification failed.
    private var keyChangeBanner: some View {
        ChatKeyChangeBannerView(
            alert: contactTrustAlert,
            contactName: peerName,
            onVerify: { showingSafetyNumbers = true },
            onAccept: { acknowledgeContactKeyChange() }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: contactTrustAlert)
    }

    private func acknowledgeContactKeyChange() {
        if KeyChangeUX.acknowledgeKeyChange(userId: peerId) {
            loadContactKTStatus()
        }
    }

    /// Refresh the at-risk state from the per-peer Keychain flag set by degraded init.
    private func refreshSessionAtRiskState() {
        let contactId = peerId
        isSessionAtRisk = SessionInitializationService.isSessionAtRisk(withPeer: contactId)
    }

    private var floodSenderId: String { peerId }

    private var isFloodSenderSuppressed: Bool {
        floodGuard.suppressedSenders.contains(floodSenderId)
    }

    private func unsuppressFloodSender() {
        IncomingFloodGuard.shared.unsuppress(senderId: floodSenderId)
    }

    private func blockAndUnsuppressFloodSender() {
        let userId = peerId
        do {
            try LocalRepositories.contacts.setBlocked(userId, true)
        } catch {
            Log.error("Flood block not saved locally for \(userId.prefix(8))…: \(error)", category: "ChatView")
        }
        BlockSyncService.shared.request(userId, blocked: true)
        IncomingFloodGuard.shared.unsuppress(senderId: floodSenderId)
    }

    @ViewBuilder
    private var deleteButtonBar: some View {
        if isEditMode && !selectedMessages.isEmpty {
            ChatSelectionBarView(
                selectedCount: selectedMessages.count,
                onDelete: deleteSelectedMessages,
                onForward: forwardSelectedMessages
            )
        }
    }
    
    var messageInputView: some View {
        IOSMessageInputView(
            text: $messageText,
            droppedImages: $chatDropImages,
            replyingTo: replyingTo,
            quoteOverride: replyQuoteText,
            editingMessage: viewModel.editingMessage,
            onSend: { attachments, fileURLs in
                if let editMsg = viewModel.editingMessage {
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
                    DraftStore.shared.clear(for: viewModel.conversation.chatId)
                    replyingTo = nil
                    replyQuoteText = nil
                    clearReplyFocus(animated: true)

                    // Sending is an explicit return to the newest message: someone who was
                    // reading history and sent something means to see it land. One call, not a
                    // flag plus a second scroll from the count change fighting it.
                    viewport.followExplicitly()
                }
            },
            onSendVoice: { url, duration, waveform in
                viewModel.sendVoiceMessage(
                    url: url, duration: duration, waveform: waveform,
                    replyTo: replyingTo, replyToContentOverride: replyQuoteText
                )
                replyingTo = nil
                replyQuoteText = nil
                clearReplyFocus(animated: true)
                // Same single path as a text send.
                viewport.followExplicitly()
            },
            onSendSticker: { ref in
                viewModel.sendSticker(ref, replyTo: replyingTo)
                replyingTo = nil
                replyQuoteText = nil
                clearReplyFocus(animated: true)
                viewport.followExplicitly()
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
        .disabled(isEditMode || viewModel.isInitializingSession)
        .overlay {
            if viewModel.isInitializingSession {
                Text(NSLocalizedString("history_sync_composer_connecting", comment: ""))
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(CTLayout.inlinePad)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.CT.bg.opacity(0.85))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Scroll to bottom button (appears when scrolled far from newest)
            if viewport.showJumpButton && !isEditMode {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        viewport.followExplicitly()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(CTIcon.font(CTIcon.control, weight: .regular))
                        .foregroundColor(Color.CT.accent)
                        .frame(width: CTLayout.controlHeight, height: CTLayout.controlHeight)
                        .glassCapsule()
                        // An unlabelled Image drops out of the accessibility tree entirely.
                        .accessibilityLabel(NSLocalizedString("scroll_to_newest", comment: "Jump to the newest message"))
                }
                .padding(.trailing, CTLayout.edgePad)
                .padding(.bottom, ChatUIConstants.Shell.scrollToBottomLift)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewport.showJumpButton)
            }
        }
    }
    

    private var canStartCall: Bool {
        guard CallsFeature.isEnabled,
              let callManager,
              case .idle = callManager.state else { return false }
        return true
    }

    var headerActions: [ChatAction] {
        ChatAction.available(canCall: canStartCall, videoEnabled: CallsFeature.isVideoEnabled)
    }

    func performHeaderAction(_ action: ChatAction) {
        switch action {
        case .search: withAnimation { isSearchActive = true }
        case .call: startCall()
        case .videoCall: startVideoCall()
        }
    }

    private func startCall() {
        startOutgoingCall(hasVideo: false)
    }

    private func startVideoCall() {
        startOutgoingCall(hasVideo: true)
    }

    private func startOutgoingCall(hasVideo: Bool) {
        guard let callManager else { return }
        Task {
            await callManager.startOutgoingCall(
                to: peerId,
                displayName: peerName,
                hasVideo: hasVideo
            )
        }
    }

    /// The InCallMiniBar (rendered at MainTabView level via `.safeAreaInset`) does not push the
    /// pushed ChatView down — TabView doesn't propagate that inset into a NavigationStack
    /// destination. So when a call is active/connecting (bar is showing), ChatView reserves the
    /// bar's height itself to keep the floating nav capsule from sitting under it.
    var callBarInset: CGFloat {
        guard CallsFeature.isEnabled, let state = callManager?.state else { return 0 }
        switch state {
        case .active, .connecting: return InCallMiniBar.barHeight
        default: return 0
        }
    }

    var navigationStatusSubtitle: String? {
        connectionManager.navigationStatusSubtitle(
            isInitializingSession: viewModel.isInitializingSession
        )
    }

    // MARK: - Computed Properties

    var filteredMessages: [TranscriptEntry] {
        let valid = viewModel.entries
        if searchText.isEmpty {
            return valid
        }
        // The words, not the stored body: "mediaId" would match every photo. Reads every row,
        // so the list follows every row while a search is open — only then.
        return valid.filter { entry in
            entry.row.readableText.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// All media messages in display order. Upload placeholders are excluded.
    private func mediaMessages(in entries: [TranscriptEntry]) -> [TranscriptRow] {
        entries.map(\.row).filter {
            guard let mc = parseMediaContent(from: $0.legacyBody) else { return false }
            return (mc.media["_placeholder"] as? Bool) != true
        }
    }

    // MARK: - Lifecycle

    private var isPreviewRuntime: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private func handleViewAppear() {
        if isPreviewRuntime {
            viewModel.onPreviewAppear()
            loadContactKTStatus()
            return
        }
        // Restore an unsent draft saved when we last left this chat.
        if viewModel.editingMessage == nil, messageText.isEmpty {
            messageText = DraftStore.shared.draft(for: viewModel.conversation.chatId)
        }
        isOnScreen = true
        markChatAsRead()
        viewModel.onViewAppear()
        loadContactKTStatus()
        refreshSessionAtRiskState()
        // Phase 2: if this contact was reached via a degraded session and has since rotated
        // their keys, opportunistically re-key to a fresh session (no-op otherwise).
        let contactId = peerId
        Task { await SessionInitializationService.shared.upgradeAtRiskSessionIfPeerFresh(userId: contactId) }
        // Who this person's devices are, when nothing recent has said. Opening the chat is the
        // trigger rather than sending, so the key server is asked once per peer per TTL and never
        // per message. Best-effort; see `refreshRecipientDevices`.
        Task { await MultiDeviceSendCoordinator.shared.refreshRecipientDevices(for: contactId) }
        setActiveChatState(isActive: true)
        ChatOnScreen.shared.appeared(viewModel.conversation.chatId)
        // Active chat owns continuous voice playback: advance to the next voice message
        // (older → newer) when one finishes, if the setting is on.
        AudioPlayerService.shared.onTrackFinished = { [weak viewModel] finishedMediaId in
            viewModel?.playNextVoiceIfContinuous(after: finishedMediaId)
        }
    }

    private func handleViewDisappear() {
        replyFocusPeekTask?.cancel()
        replyFocusPeekTask = nil
        isOnScreen = false
        VideoNotePlayback.shared.collapse()
        guard !isPreviewRuntime else { return }
        // Whatever arrived while this chat was on screen has been seen.
        markChatAsRead()
        // Preserve a half-typed message across navigation. Skip while editing,
        // so the edit buffer never leaks into the new-message draft.
        if viewModel.editingMessage == nil {
            DraftStore.shared.save(messageText, for: viewModel.conversation.chatId)
        }
        setActiveChatState(isActive: false)
        ChatOnScreen.shared.disappeared(viewModel.conversation.chatId)
        AudioPlayerService.shared.onTrackFinished = nil
    }

    private func handleContactKeyChanged(_ note: Notification) {
        guard let changedId = note.userInfo?["userId"] as? String,
              changedId == peerId else { return }
        loadContactKTStatus()
    }

    private func setActiveChatState(isActive: Bool) {
        KeyChangeUX.setActiveChatContact(isActive ? peerId : nil)
    }

    // MARK: - Actions

    private func markChatAsRead() {
        let chatId = viewModel.conversation.chatId
        // Our other devices learn how far this chat is read — whether or not this one counted
        // anything unread: a message that arrived on screen was read without ever being counted.
        ReadSyncOutbox.shared.noteRead(chatId: chatId)
        guard let unread = try? LocalRepositories.chats.chat(chatId)?.unreadCount, unread > 0 else { return }
        _ = try? LocalRepositories.chats.setUnread(chatId, 0)
    }

    func toggleMessageSelection(_ message: TranscriptRow) {
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
    
    func hideKeyboard() {
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
    return NavigationStack {
        ChatView(conversation: Conversation(chatId: chat.id, peerId: user.id), context: context)
            .environment(\.managedObjectContext, context)
            .environment(ChatsViewModel())
    }
}
#endif

/// Hands its content the peer's current name. `ChatViewModel` is `@Observable`, and Observation
/// does not track a managed object's attributes, so reading `otherUser.resolvedDisplayName` in
/// `ChatView.body` subscribed to nothing: a profile applied while the chat was open renamed the
/// chat list row (a `@FetchRequest`) and left this header on the old name until the chat was
/// reopened. `@ObservedObject` re-renders on the object's `objectWillChange`, which a save or a
/// merge into the view context fires.
struct ObservedPeerName<Content: View>: View {
    let userId: String
    let content: (String) -> Content

    var body: some View {
        content(ContactsLive.shared.contact(userId)?.resolvedDisplayName
            ?? DisplayNameGenerator.generate(from: userId))
    }
}
