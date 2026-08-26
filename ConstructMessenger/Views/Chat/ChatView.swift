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
    /// Lazy holder — SwiftUI re-runs View.init on parent re-render; we must not
    /// allocate ChatViewModel there or discarded copies spam deinit / waste work.
    @State private var lazyViewModel: LazyChatViewModel
    private var viewModel: ChatViewModel { lazyViewModel.value }
    /// Whoever owns the scroll position on this path. Chosen once, in `init`.
    ///
    /// Sampling the flag in `body` would let a mid-session flip put two owners on screen, which is
    /// build 586: two `ChatScrollManager`s on one NotificationCenter, each arming a pin series
    /// against the other. The Diagnostics toggle therefore lands on the next push of a chat.
    @State private var viewport: any TranscriptViewportOwning
    /// Whether this view was built on the owned-inset path. Read from `viewport`'s type would be a
    /// second carrier of the same fact; this one is written once beside it.
    private let usesOwnedInset: Bool
    private var connectionManager = ConnectionStatusManager.shared
    @State private var messageText = ""
    @State private var replyingTo: Message?
    /// When non-nil, the user selected a partial quote from `replyingTo` for reply.
    @State private var replyQuoteText: String? = nil
    /// Message opened for "Quote & Reply" selection sheet.
    @State private var quotingMessage: Message? = nil
    /// Soft reply focus — lowercased message ids that stay full-opacity; others dim.
    /// Empty = idle chat (no visual change). See ``ChatUIConstants.ReplyFocus``.
    @State private var replyFocusIds: Set<String> = []
    @State private var replyFocusPeekTask: Task<Void, Never>?
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
    /// True when the session with this contact was established via a degraded (stale-SPK) init.
    @State private var isSessionAtRisk = false
    /// Safety Numbers sheet after key-change "Verify".
    @State private var showingSafetyNumbers = false

    @State private var containerWidth: CGFloat = ChatUIConstants.Bubble.defaultContainerWidth
    /// Current height of the bottom composer (safeAreaInset). Tracked so we can re-pin the
    /// scroll when it changes — see the composer's `.onGeometryChange` below.
    @State private var composerHeight: CGFloat = 0
    /// Bottom safe area, and the scroll view's own height. Held because the keyboard moves both
    /// while leaving the composer's height alone, and a latch blind to that reads a keyboard
    /// animation as a settled layout.
    ///
    /// Both are now written from the geometry tick, which is where they are measured. They exist as
    /// state only because the composer's own report — which cannot see the scroll view — needs the
    /// two numbers it does not carry. `bottomSafeAreaInset` was declared here and never assigned
    /// at all until 2026-08-21.
    @State private var bottomSafeAreaInset: CGFloat = 0
    @State private var transcriptContainerHeight: CGFloat = 0
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
    @State private var anchorSample: TranscriptRowSample?
    /// Where the row a guest scroll is heading for sits. Same reporter as the anchor, installed on
    /// a different row and for a different question: the anchor's *movement* is the reading
    /// position, this row's *position* is the destination.
    @State private var scrollTargetSample: TranscriptRowSample?
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
    @State private var geometryHistory = TranscriptGeometryHistory()
    // "Is the layout settled enough to read geometry as intent" lives with the owner
    // (`layoutPrimed`). It was a `@State` here and was armed from the wrong evidence.

    private enum Layout {
        static let composerHorizontalPadding = ChatUIConstants.Shell.composerHorizontalPadding
        static let composerBottomPadding = ChatUIConstants.Shell.composerBottomPadding
        static let messageBottomClearance = ChatUIConstants.Shell.messageBottomClearance
        /// Extra band below the status-bar safe area (≈ nav capsule height + margin) covered
        /// by the top scrim so scrolling text blurs/fades before it reaches the clock & signal.
        static let topScrimUnderSafeArea = ChatUIConstants.Shell.topScrimUnderSafeArea
        /// Same cutoff as ``ChatScrollManager/heightRepinThreshold`` — layout noise, not a pin trigger.
        static let geometryLogThreshold = ChatScrollManager.heightRepinThreshold
    }

    /// Probe log for viewport moves. Gated by ``ChatScrollManager.verboseGeometryLogging`` —
    /// default off so thermal/export sessions stay readable. Requires a real move/growth even
    /// during opening (the old `|| isOpening` branch logged every layout pass).
    private func logScrollGeometryIfChanged(from old: ChatScrollGeometry, to new: ChatScrollGeometry) {
        guard ChatScrollManager.verboseGeometryLogging else { return }
        let moved = abs(new.visibleMinY - old.visibleMinY) >= Layout.geometryLogThreshold
        let grew = abs(new.contentHeight - old.contentHeight) >= Layout.geometryLogThreshold
        guard moved || grew else { return }
        ChatScrollManager.logGeometry(
            "SCROLL_GEO content=\(Int(new.contentHeight))pt viewport=[\(Int(new.visibleMinY))…\(Int(new.visibleMinY + (new.contentHeight - new.distanceFromBottom - new.visibleMinY)))] fromBottom=\(Int(new.distanceFromBottom)) msgs=\(viewModel.messages.count) \(viewport.stateDescription)"
        )
    }

    init(chat: Chat, context: NSManagedObjectContext) {
        _lazyViewModel = State(wrappedValue: LazyChatViewModel {
            ChatViewModel(chat: chat, context: context)
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

        // Floating capsule glass panels (top nav + bottom input) over scroll, following Apple's capsulization
        ZStack {
            // Full-bleed chat background so the floating input capsule sits over a continuous
            // surface — without this the ScrollView's own background stops at the safe area and
            // the bottom safe-area band renders with the window background, reading as an opaque
            // strip under the capsule.
            Color.CT.bg.ignoresSafeArea()

            // Message list — base layer, scrolls underneath the floating capsules
            transcript(renderedMessages)
                .onChange(of: viewModel.messages.count) { oldCount, count in
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
                        // For media messages pre-fill with caption, not the raw JSON payload
                        if let mc = parseMediaContent(from: editMsg.displayText) {
                            messageText = mc.caption
                        } else {
                            messageText = editMsg.displayText
                        }
                    }
                }

            // Top scrim so scrolling text fades before the status bar / floating nav.
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

            // === Floating capsule glass panels (Apple capsulization) ===
            // Top: nav + banners (capsule style)
            VStack(spacing: ChatUIConstants.Shell.floatingChromeSpacing) {
                chatNavBar
                    .padding(.horizontal, ChatUIConstants.Shell.floatingChromeHorizontal)
                    .padding(.top, ChatUIConstants.Shell.floatingChromeTop + callBarInset)

                floodBurstBanner

                keyChangeBanner

                atRiskBanner

                deleteButtonBar

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)

        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .modifier(ComposerPlacement(usesOverlay: usesOwnedInset) { composer })
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
        .sheet(isPresented: $showingSafetyNumbers) {
            if let user = viewModel.chat.otherUser,
               let deviceId = KeyChangeUX.safetyDeviceId(for: user) {
                SafetyNumberView(
                    theirDeviceId: deviceId,
                    theirDisplayName: user.resolvedDisplayName
                )
            }
        }
        .sheet(item: $quotingMessage) { msg in
            QuoteSelectionSheet(message: msg) { selectedQuote in
                replyingTo = msg
                replyQuoteText = selectedQuote
                setComposeReplyFocus(messageId: msg.id)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear(perform: handleViewAppear)
        .onReceive(NotificationCenter.default.publisher(for: .contactKeyChanged), perform: handleContactKeyChanged)
        // Session init/degrade happens during send; re-read the at-risk flag when it settles.
        .onChange(of: viewModel.isInitializingSession) { _, _ in refreshSessionAtRiskState() }
        // Posted when an at-risk session is auto-upgraded — refresh the banner so it disappears.
        .onReceive(NotificationCenter.default.publisher(for: .sessionAtRiskChanged)) { note in
            if (note.userInfo?["userId"] as? String) == viewModel.chat.otherUser?.id {
                refreshSessionAtRiskState()
            }
        }
        .onDisappear(perform: handleViewDisappear)
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
            status: contactKTStatus,
            contactName: viewModel.chat.otherUser?.resolvedDisplayName
                ?? NSLocalizedString("chat", comment: ""),
            onVerify: { showingSafetyNumbers = true },
            onAccept: { acknowledgeContactKeyChange() }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: contactKTStatus)
    }

    private func acknowledgeContactKeyChange() {
        guard let userId = viewModel.chat.otherUser?.id else { return }
        if KeyChangeUX.acknowledgeKeyChange(userId: userId, context: viewContext) {
            loadContactKTStatus()
        }
    }

    /// Refresh the at-risk state from the per-peer Keychain flag set by degraded init.
    private func refreshSessionAtRiskState() {
        guard let contactId = viewModel.chat.otherUser?.id, !contactId.isEmpty else {
            isSessionAtRisk = false
            return
        }
        isSessionAtRisk = KeychainManager.shared.loadSessionAtRiskFlag(for: contactId)
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
            let userId = user.id
            // Durable server-side block (best-effort; local isBlocked already drives the drop).
            Task {
                do { _ = try await UserServiceClient.shared.blockUser(userId: userId) }
                catch { Log.error("Flood block sync failed for \(userId.prefix(8))… (local kept): \(error)", category: "ChatView") }
            }
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
                    DraftStore.shared.clear(for: viewModel.chat.id)
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
                viewModel.sendVoiceMessage(url: url, duration: duration, waveform: waveform)
                // Same single path as a text send.
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
        .disabled(isEditMode)
        .overlay(alignment: .bottomTrailing) {
            // Scroll to bottom button (appears when scrolled far from newest)
            if viewport.showJumpButton && !isEditMode {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        viewport.followExplicitly()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: CTLayout.callIconSize))
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
            },
            onKTWarningTap: {
                if contactKTStatus == .keyChanged || contactKTStatus == .failed {
                    showingSafetyNumbers = true
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

    /// Infinite-scroll entry point. Policy lives in `ChatScrollManager.shouldLoadOlderHistory` so
    /// entry-time LazyVStack top materialisation cannot widen the window (TODO 34).
    // MARK: - Transcript container wiring
    //
    // Each of these was an inline closure at the call site until PR-2. Twelve arguments, five of
    // them multi-line closures, over a two-generic view: the type checker gave up
    // ("unable to type-check this expression in reasonable time"). Named methods are also what
    // makes the next PR readable — the flag will swap the container, not four hundred lines.

    /// The transcript container, built away from the modifier chain that decorates it.
    ///
    /// Not a style choice. Twelve arguments over a two-generic view, followed by ten `.onChange`
    /// blocks, is one expression as far as the type checker is concerned, and it gives up on it —
    /// "unable to type-check this expression in reasonable time", twice while this PR was written.
    /// The extraction is what keeps the file compilable, and it is why the container's arguments
    /// are named methods rather than inline closures.
    @ViewBuilder
    private func transcript(_ renderedMessages: [Message]) -> some View {
        if usesOwnedInset {
            ChatTranscriptScrollView(
                bottomInset: transcriptBottomPad,
                mode: ownedViewport?.mode ?? .following,
                layoutPrimed: viewport.layoutPrimed,
                // Nil unless the sample is of the row currently bound, so a stale one cannot be
                // read as a measurement of the new anchor.
                anchor: anchorSample?.messageId == viewport.heldMessageId ? anchorSample : nil,
                scrollTarget: transcriptScrollTarget,
                landRequest: ownedViewport?.landRequest ?? 0,
                onLanded: { ownedViewport?.noteTailLanded() },
                onReachedScrollTarget: { ownedViewport?.noteScrollTargetResolved() },
                onGeometry: { handleTranscriptGeometry(from: geometryHistory.last, to: $0) },
                onUserInteraction: { viewport.noteScrollPhase(.tracking) }
            ) {
                VStack(spacing: ChatUIConstants.Shell.listSpacing) {
                    loadMoreSentinel(renderedMessages)
                    transcriptRows(renderedMessages)
                    Color.clear.frame(height: Layout.messageBottomClearance)
                }
                .padding(.top, ChatUIConstants.Shell.scrollContentTopPad + callBarInset)
                .padding(.horizontal)
                .coordinateSpace(name: Self.transcriptContentSpace)
                .environment(\.containerWidth, containerWidth)
            }
            // The legacy path clears the badge from `registerTranscriptProxy`, which this container
            // never calls — it has no `ScrollViewReader`, so `onProxyReady` does not exist here.
            // Opening a chat therefore left the badge standing for the whole owned-path build.
            .onAppear { LocalNotificationManager.shared.clearBadge() }
        } else {
            legacyTranscript(renderedMessages)
        }
    }

    /// Content-space name the held row reports its position in. One name, declared beside the only
    /// two places that use it, so the reporter and the reader cannot drift apart.
    static let transcriptContentSpace = "transcript.content"

    /// The viewport when it is the owned one. `viewport` is the protocol, and three of its inputs
    /// (mode, the two request tokens) exist only on this side of the flag.
    private var ownedViewport: ChatViewport? { viewport as? ChatViewport }

    /// The pending guest scroll, paired with its measurement.
    ///
    /// The sample is passed only when it is of the row actually being asked for. A stale one — the
    /// previous jump's row, still in `scrollTargetSample` because nothing clears it — would be read
    /// as this jump's destination and land the viewport on the wrong message. Same guard, and the
    /// same reason, as the anchor's `messageId ==` test above.
    private var transcriptScrollTarget: TranscriptScrollTarget? {
        guard let owned = ownedViewport, let targetId = owned.scrollTargetId else { return nil }
        return TranscriptScrollTarget(
            request: owned.scrollRequest,
            anchor: owned.scrollTargetAnchor,
            sample: scrollTargetSample?.messageId == targetId ? scrollTargetSample : nil
        )
    }

    @ViewBuilder
    private func legacyTranscript(_ renderedMessages: [Message]) -> some View {
        ChatTranscriptContainer(
            rowSpacing: ChatUIConstants.Shell.listSpacing,
            topContentPad: ChatUIConstants.Shell.scrollContentTopPad + callBarInset,
            bottomContentPad: transcriptBottomPad,
            accessibilityIdentifier: A11y.Chat.messageList,
            usesEagerStack: usesOwnedInset,
            onProxyReady: registerTranscriptProxy,
            onGeometryChange: handleTranscriptGeometry,
            onScrollPhaseChange: handleTranscriptScrollPhase,
            onTapBackground: hideKeyboard,
            onBottomAnchorVisible: logBottomAnchorVisibility,
            sentinel: { loadMoreSentinel(renderedMessages) },
            rows: { transcriptRows(renderedMessages) }
        )
        .environment(\.containerWidth, containerWidth)
    }

    /// Room left at the end of the transcript for the composer.
    ///
    /// Hoisted out of the container's argument list on purpose: that call takes twelve arguments
    /// over a two-generic view, and a ternary inside it is enough to make the type checker give up
    /// — which it did, with "unable to type-check this expression in reasonable time".
    ///
    /// On the legacy path the composer is a safe-area inset and the system reserves its height, so
    /// only the constant clearance belongs in the content. On the owned-inset path nothing reserves
    /// anything and this number is the whole reason the tail is not under the glass.
    private var transcriptBottomPad: CGFloat {
        guard usesOwnedInset else { return Layout.messageBottomClearance }
        return composerHeight + Layout.messageBottomClearance
    }

    /// The composer, and the one place its height is reported.
    ///
    /// On the owned-inset path this view is an overlay and the height it reports becomes the
    /// transcript's `bottomContentPad` — the tail sits above the glass because the content says so,
    /// not because a corrective scroll pushed it there. On the legacy path it is a
    /// `.safeAreaInset` and the same number is only a pin trigger.
    private var composer: some View {
        messageInputView
            .padding(.horizontal, Layout.composerHorizontalPadding)
            .padding(.bottom, Layout.composerBottomPadding)
            .background(Color.clear)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { _, newHeight in
                guard newHeight.isFinite, newHeight >= 0 else { return }
                // Sub-point thrash from the keyboard and the glass is not a layout change. The
                // same cutoff the owner uses to latch, so the pad and the latch cannot disagree
                // about whether anything moved.
                let changed = abs(newHeight - composerHeight) > ChatViewport.Threshold.padNoise
                composerHeight = newHeight
                guard changed else { return }
                reportComposerGeometry()
                // Legacy path only: it has no owned pad, so a growing inset dematerialises the
                // lazy list and something has to scroll. Reading history with a reply open, that
                // something must be the replied-to message rather than the bottom.
                if !usesOwnedInset, !viewport.isFollowing,
                   let anchorId = (replyingTo ?? viewModel.editingMessage)?.id {
                    viewport.scrollTo(messageId: anchorId, anchor: .center, animated: false)
                }
            }
    }

    /// All three bottom-inset sources in one call. A keyboard moves the safe area and the container
    /// without touching the composer's own height, so a latch fed by the composer alone reads the
    /// keyboard as a settled layout.
    private func reportComposerGeometry() {
        viewport.noteComposerGeometry(
            composerHeight: composerHeight,
            safeAreaBottom: bottomSafeAreaInset,
            containerHeight: transcriptContainerHeight
        )
    }

    private func registerTranscriptProxy(_ proxy: ScrollViewProxy) {
        viewport.registerProxy(proxy)
        LocalNotificationManager.shared.clearBadge()
        // .defaultScrollAnchor(.bottom) + LazyVStack + composer safeAreaInset often lands the
        // first offset out of range → blank list until a gesture. Multi-pass non-animated pin
        // covers inset settle and FRC load-more churn.
        //
        // Only when there is a transcript to open. On a cold entry there is not: the store
        // publishes from `viewModel.onViewAppear()`, which runs after this, so the list is empty
        // here and the opening is armed by the 0 → N change instead. Declaring the opening
        // finished on an empty list is what let load-more growth take the animated branch and
        // blank the chat.
        viewport.noteTranscriptAppeared(messageCount: viewModel.messages.count)
    }

    private func handleTranscriptGeometry(from old: ChatScrollGeometry, to metrics: ChatScrollGeometry) {
        // The inset latch is a per-tick measurement, so it is fed per tick. Its two previous call
        // sites both fired *because* something had moved, which meant `noteInsetDelta` never once
        // saw a quiet pass and `insetSettling` stayed true from the first container measurement
        // onward — see `ChatViewport.insetSettling`. The latch has its own `padNoise` threshold;
        // pre-filtering on its behalf is what broke it.
        //
        // Owned path only. The legacy owner answers the same call with `pinToBottom(.composerInset)`
        // — a scroll, not a measurement — so feeding it every tick would arm a pin per frame. Its
        // one caller stays the composer's own change report, which is all it ever watched.
        if usesOwnedInset {
            viewport.noteComposerGeometry(
                composerHeight: composerHeight,
                safeAreaBottom: metrics.safeAreaBottom,
                containerHeight: metrics.containerHeight
            )
        }
        viewport.updateGeometry(metrics, messageCount: viewModel.messages.count)
        // The blank chat is a *geometry* state and no log has ever shown it: we know where the
        // messages are and nothing about where the viewport is. One line per meaningful move
        // answers "was the offset wrong, or were the cells absent".
        logScrollGeometryIfChanged(from: old, to: metrics)
        // Ignore zero-width passes during mid-layout; avoid thrashing on sub-pixel noise.
        if metrics.width > 1, abs(metrics.width - containerWidth) > 0.5 {
            containerWidth = metrics.width
        }
        // Held for the composer's own report, which cannot see the scroll view. The latch was
        // already fed this tick, with fresher numbers than these; the thresholds are here because
        // these two are `@State` and every write costs a body pass.
        if metrics.containerHeight.isFinite,
           abs(metrics.containerHeight - transcriptContainerHeight) > 0.5 {
            transcriptContainerHeight = metrics.containerHeight
        }
        if metrics.safeAreaBottom.isFinite,
           abs(metrics.safeAreaBottom - bottomSafeAreaInset) > 0.5 {
            bottomSafeAreaInset = metrics.safeAreaBottom
        }
        // Offer the stick on the pass where following has just stopped and none is bound. Here
        // rather than in an `.onChange(of: isFollowing)` so the offer sits next to the geometry
        // that decided it; `bindAnchorRow` remains the authority on whether to take it.
        //
        // The two cheap checks are not redundant with that authority — they keep `filteredMessages`
        // (an O(n) filter) off the per-frame path, and it has to be that list rather than
        // `viewModel.messages`: it is what the rows are built from, so it is the only one whose
        // first element is guaranteed to be a row that can install the reporter.
        if !viewport.isFollowing, viewport.heldMessageId == nil {
            viewport.bindAnchorRow(filteredMessages.first?.id)
        }
        geometryHistory.last = metrics
        // Near-top geometry is the reliable trigger once the user scrolls up: sentinel `onAppear`
        // alone misses the case where the top stayed materialised from entry (no second appear)
        // and would never widen the window.
        attemptLoadOlderHistory()
    }

    private func handleTranscriptScrollPhase(_ phase: ScrollPhase) {
        // Phase → intent is a decision, so it lives in ChatScrollManager where a test can reach it.
        viewport.noteScrollPhase(phase)
    }

    private func logBottomAnchorVisibility(_ visible: Bool) {
        ChatScrollManager.logGeometry(
            visible
                ? "SCROLL_ANCHOR bottom visible (primed=\(viewport.layoutPrimed))"
                : "SCROLL_ANCHOR bottom left the viewport"
        )
    }

    /// Infinite-scroll sentinel at the TOP (oldest edge). No button — history loads as the person
    /// reaches the oldest edge. `LazyVStack` materialises this on first layout even when
    /// bottom-anchored; the load is gated by `ChatScrollManager.shouldLoadOlderHistory` (TODO 34).
    @ViewBuilder
    private func loadMoreSentinel(_ renderedMessages: [Message]) -> some View {
        if viewModel.hasMoreMessages && !renderedMessages.isEmpty {
            Group {
                if viewModel.isLoadingMore {
                    ProgressView()
                        .padding(.vertical, ChatUIConstants.Shell.listSpacing)
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

    /// The message rows, lifted out of `body` so `ChatTranscriptContainer` owns only the scroll.
    /// Every callback still belongs to `ChatView` — the container never sees a view model.
    @ViewBuilder
    private func transcriptRows(_ renderedMessages: [Message]) -> some View {
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
                                setComposeReplyFocus(messageId: msg.id)
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
                            onTapMedia: { msg, itemIndex in
                                galleryStartItem = GalleryStartItem(id: msg.id, itemIndex: itemIndex)
                            },
                            onEdit: { msg in
                                viewModel.editingMessage = msg
                            },
                            onReplyWithQuote: { msg, _ in
                                quotingMessage = msg
                            },
                            onJumpToReply: { msg in
                                peekReplyChain(for: msg)
                            },
                            onReact: { msg, emoji in
                                viewModel.sendReaction(msg, emoji: emoji)
                            }
                        )
                        .id(message.id)
                        // The LAST message only, and no longer just a probe. Auto-scroll
                        // promises the newest message is on screen; this is the only place
                        // that can tell whether the promise holds. Build 583 showed it
                        // broken for seconds at a time — the transcript measured 5792pt,
                        // the pin anchored there, the height settled at 3952pt and the
                        // viewport was left 922pt past the end. See
                        // `ChatScrollManager.shouldRecoverStrandedViewport`.
                        .background {
                            // At most two rows measure themselves: the held anchor, and the row a
                            // guest scroll is trying to reach. Thirty reporters would be a
                            // per-frame cost for a number that is meaningless for every row but
                            // those, which is why the target is named before it is measured rather
                            // than every row being measured in case someone asks.
                            if usesOwnedInset,
                               message.id == viewport.heldMessageId || message.id == ownedViewport?.scrollTargetId {
                                GeometryReader { proxy in
                                    Color.clear.onChange(
                                        of: proxy.frame(in: .named(Self.transcriptContentSpace)),
                                        initial: true
                                    ) { _, frame in
                                        let sample = TranscriptRowSample(
                                            messageId: message.id,
                                            minY: frame.minY,
                                            height: frame.height
                                        )
                                        if message.id == viewport.heldMessageId { anchorSample = sample }
                                        if message.id == ownedViewport?.scrollTargetId { scrollTargetSample = sample }
                                    }
                                }
                            }
                        }
                        .onAppear {
                            if index == renderedMessages.count - 1 {
                                ChatScrollManager.logGeometry(
                                    "SCROLL_ANCHOR last message visible (\(message.id.prefix(8))…, idx=\(index)/\(renderedMessages.count))"
                                )
                                viewport.noteLastMessageVisible(true, searchActive: isSearchActive)
                            }
                        }
                        .onDisappear {
                            if index == renderedMessages.count - 1 {
                                ChatScrollManager.logGeometry(
                                    "SCROLL_ANCHOR last message left the viewport (\(message.id.prefix(8))…)"
                                )
                                viewport.noteLastMessageVisible(false, searchActive: isSearchActive)
                            }
                        }
                        .opacity(replyFocusOpacity(for: message))
                        .animation(
                            .easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration),
                            value: replyFocusIds
                        )

                        // Add spacing after each message
                        if index < renderedMessages.count - 1 {
                            Spacer()
                                .frame(height: message.spacingAfterMessage(at: index, in: renderedMessages))
                        }
                    }
                }
    }

    private func attemptLoadOlderHistory() {
        guard viewport.shouldLoadOlderHistory(
            isSearchActive: isSearchActive,
            isLoadingMore: viewModel.isLoadingMore,
            hasMoreMessages: viewModel.hasMoreMessages
        ) else { return }
        viewModel.loadMoreMessages(trigger: .indicatorAppeared)
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

    /// The InCallMiniBar (rendered at MainTabView level via `.safeAreaInset`) does not push the
    /// pushed ChatView down — TabView doesn't propagate that inset into a NavigationStack
    /// destination. So when a call is active/connecting (bar is showing), ChatView reserves the
    /// bar's height itself to keep the floating nav capsule from sitting under it.
    private var callBarInset: CGFloat {
        guard CallsFeature.isEnabled, let state = callManager?.state else { return 0 }
        switch state {
        case .active, .connecting: return InCallMiniBar.barHeight
        default: return 0
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

    // MARK: - Soft reply focus (dim non-related bubbles)

    private func replyFocusOpacity(for message: Message) -> Double {
        guard !isEditMode, !replyFocusIds.isEmpty else {
            return ChatUIConstants.ReplyFocus.focusedOpacity
        }
        let id = message.id.lowercased()
        if replyFocusIds.contains(id) {
            return ChatUIConstants.ReplyFocus.focusedOpacity
        }
        return ChatUIConstants.ReplyFocus.dimmedOpacity
    }

    /// Compose-reply focus: keep the quoted parent bright while the reply bar is up.
    private func setComposeReplyFocus(messageId: String) {
        replyFocusPeekTask?.cancel()
        replyFocusPeekTask = nil
        // Do not wrap in withAnimation — each bubble already has
        // `.animation(..., value: replyFocusIds)`. A second transaction here
        // animated the whole LazyVStack with composer inset change → flash.
        replyFocusIds = [messageId.lowercased()]
    }

    /// Take the reader to one message, if the transcript is showing it.
    ///
    /// Every guest scroll goes through here, for two reasons the call sites cannot handle
    /// individually.
    ///
    /// **The id is resolved against the rendered list, and the rendered one is what travels on.**
    /// `peekReplyChain` lowercases both ids before it asks, `Message.id` is not lowercase, and the
    /// row that installs the target's reporter matches on `message.id` — so an unresolved id asks
    /// for a row that, to every comparison downstream, does not exist. One normalisation, at the
    /// boundary, rather than a `.lowercased()` at each of the places that compare.
    ///
    /// **A message outside the loaded window is refused here.** The destination is measured by a
    /// reporter installed on the target row, so a message the transcript has not rendered has
    /// nowhere to put one, and the request would sit unfulfilled forever. Saying so is the point: a
    /// jump that silently does nothing is the defect this whole change closes, and replacing it
    /// with a differently-shaped silence would be no better.
    private func jumpToMessage(_ messageId: String, anchor: UnitPoint = .center) {
        guard let rendered = filteredMessages.first(
            where: { $0.id.caseInsensitiveCompare(messageId) == .orderedSame }
        ) else {
            Log.info(
                "SCROLL_GUEST[not_rendered]: \(messageId.prefix(8))… is not in the loaded transcript — no jump",
                category: "ChatView"
            )
            return
        }
        viewport.scrollTo(messageId: rendered.id, anchor: anchor, animated: true)
    }

    /// Tap on in-bubble reply strip: scroll to parent, keep parent + child bright briefly.
    private func peekReplyChain(for message: Message) {
        let childId = message.id.lowercased()
        let parentId = (message.replyToMessageId ?? "").lowercased()
        guard !parentId.isEmpty else { return }

        replyFocusPeekTask?.cancel()
        withAnimation(.easeInOut(duration: ChatUIConstants.ReplyFocus.animationDuration)) {
            replyFocusIds = [parentId, childId]
        }
        // Prefer scrolling to the parent (what the user is looking for).
        jumpToMessage(parentId)

        // Hold while composing a reply to this parent; otherwise auto-clear.
        let holdParent = parentId
        replyFocusPeekTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: ChatUIConstants.ReplyFocus.peekHoldNanoseconds)
            guard !Task.isCancelled else { return }
            if replyingTo?.id.lowercased() == holdParent {
                // Compose focus owns the set now.
                return
            }
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
            messageText = DraftStore.shared.draft(for: viewModel.chat.id)
        }
        markChatAsRead()
        viewModel.onViewAppear()
        loadContactKTStatus()
        refreshSessionAtRiskState()
        // Phase 2: if this contact was reached via a degraded session and has since rotated
        // their keys, opportunistically re-key to a fresh session (no-op otherwise).
        if let contactId = viewModel.chat.otherUser?.id, !contactId.isEmpty {
            Task { await SessionInitializationService.shared.upgradeAtRiskSessionIfPeerFresh(userId: contactId) }
        }
        setActiveChatState(isActive: true)
        // Active chat owns continuous voice playback: advance to the next voice message
        // (older → newer) when one finishes, if the setting is on.
        AudioPlayerService.shared.onTrackFinished = { [weak viewModel] finishedMediaId in
            viewModel?.playNextVoiceIfContinuous(after: finishedMediaId)
        }
    }

    private func handleViewDisappear() {
        replyFocusPeekTask?.cancel()
        replyFocusPeekTask = nil
        guard !isPreviewRuntime else { return }
        // Preserve a half-typed message across navigation. Skip while editing,
        // so the edit buffer never leaks into the new-message draft.
        if viewModel.editingMessage == nil {
            DraftStore.shared.save(messageText, for: viewModel.chat.id)
        }
        setActiveChatState(isActive: false)
        AudioPlayerService.shared.onTrackFinished = nil
    }

    private func handleContactKeyChanged(_ note: Notification) {
        guard let changedId = note.userInfo?["userId"] as? String,
              changedId == viewModel.chat.otherUser?.id else { return }
        loadContactKTStatus()
    }

    private func setActiveChatState(isActive: Bool) {
        guard let contactId = viewModel.chat.otherUser?.id, !contactId.isEmpty else { return }
        KeyChangeUX.setActiveChatContact(isActive ? contactId : nil)
        // A contact whose key is not pinned has no session for the core to schedule heartbeats
        // against; telling it a chat opened would name a peer it has never heard of.
        guard let peerContactId = SessionAddressing.contactId(forPeer: contactId) else { return }
        _ = try? CryptoManager.shared.handleOrchestratorEvent(
            .activeChatChanged(contactId: peerContactId, isActive: isActive),
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
    return NavigationStack {
        ChatView(chat: chat, context: context)
            .environment(\.managedObjectContext, context)
    }
}
#endif
