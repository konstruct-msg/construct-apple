//
//  ChatView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData
import UniformTypeIdentifiers
import Combine

struct ChatView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatsViewModel.self) private var chatsViewModel
    /// Lazy holder — SwiftUI re-runs View.init on parent re-render; we must not
    /// allocate ChatViewModel there or discarded copies spam deinit / waste work.
    @State private var lazyViewModel: LazyChatViewModel
    private var viewModel: ChatViewModel { lazyViewModel.value }
    @State private var scrollManager = ChatScrollManager()
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
    // The opening window ("all auto-scrolls stay non-animated until the first pin settles") now
    // lives in `scrollManager.isOpening`. It was a `@State` here and was armed from the wrong
    // evidence — see `ChatScrollManager.isOpening`.

    private enum Layout {
        static let composerHorizontalPadding = ChatUIConstants.Shell.composerHorizontalPadding
        static let composerBottomPadding = ChatUIConstants.Shell.composerBottomPadding
        static let messageBottomClearance = ChatUIConstants.Shell.messageBottomClearance
        /// Extra band below the status-bar safe area (≈ nav capsule height + margin) covered
        /// by the top scrim so scrolling text blurs/fades before it reaches the clock & signal.
        static let topScrimUnderSafeArea = ChatUIConstants.Shell.topScrimUnderSafeArea
        /// Below this a viewport move / content growth is layout noise and is not logged.
        static let geometryLogThreshold: CGFloat = 24
    }

    /// Combined scroll metrics so a single `onScrollGeometryChange` drives both
    /// offset tracking and container width (two modifiers caused multi-update-per-frame).
    private struct ChatScrollGeometry: Equatable {
        /// Points of content below the visible rect (0 ≈ at bottom). Uses `visibleRect`,
        /// not the inset-blind `contentOffset + container − contentSize` formula.
        var distanceFromBottom: CGFloat
        var width: CGFloat
        /// Content shorter than the viewport ⇒ nothing to jump to — the FAB must never show.
        var contentFits: Bool
        /// Total laid-out height. Grows after the opening pins when media resolves.
        var contentHeight: CGFloat
        /// Top of the viewport in content coordinates — the missing half of every blank-chat report.
        var visibleMinY: CGFloat
    }

    /// One line per meaningful viewport move. The blank chat has never appeared in a log because
    /// nothing recorded *where the viewport was* — only what the store published. Thresholded so a
    /// settled list is silent and an opening is fully traced.
    private func logScrollGeometryIfChanged(from old: ChatScrollGeometry, to new: ChatScrollGeometry) {
        let moved = abs(new.visibleMinY - old.visibleMinY) >= Layout.geometryLogThreshold
        let grew = abs(new.contentHeight - old.contentHeight) >= Layout.geometryLogThreshold
        guard moved || grew || scrollManager.isOpening else { return }
        Log.debug(
            "SCROLL_GEO content=\(Int(new.contentHeight))pt viewport=[\(Int(new.visibleMinY))…\(Int(new.visibleMinY + (new.contentHeight - new.distanceFromBottom - new.visibleMinY)))] fromBottom=\(Int(new.distanceFromBottom)) msgs=\(viewModel.messages.count) opening=\(scrollManager.isOpening) autoScroll=\(scrollManager.shouldScrollToBottom)",
            category: "ChatScrollManager"
        )
    }

    init(chat: Chat, context: NSManagedObjectContext) {
        _lazyViewModel = State(wrappedValue: LazyChatViewModel {
            ChatViewModel(chat: chat, context: context)
        })
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ChatUIConstants.Shell.listSpacing) {
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
                                            .font(CTFont.regular(ChatUIConstants.Typography.captionSize))
                                            .foregroundColor(Color.CT.accentDim)
                                            .padding(.vertical, ChatUIConstants.Shell.listSpacing)
                                    }
                                }
                                Spacer()
                            }
                            .id("loadMoreIndicator")
                            .onAppear {
                                // Fires on entering a chat, not only on scrolling up: LazyVStack
                                // materialises top-down, so this indicator appears during the
                                // first layout even though the scroll is anchored to the bottom.
                                // Tagged so the log can tell it apart from a real tap — see TODO 34.
                                if !viewModel.isLoadingMore && !isSearchActive {
                                    viewModel.loadMoreMessages(trigger: .indicatorAppeared)
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
                                    }
                                )
                                .id(message.id)
                                // Probe on the LAST message only. The bottom anchor already tells us
                                // the viewport reaches the end of the list (build 581) — what it
                                // cannot tell us is whether the last *message* is in that view. If
                                // this fires while the screen is blank, the cells are materialised
                                // and drawing nothing; if the anchor fires and this does not, there
                                // is something between them holding ~500pt, which is what the
                                // content-height oscillation (651→2542→4018→3557) points at.
                                .onAppear {
                                    if index == renderedMessages.count - 1 {
                                        Log.debug("SCROLL_ANCHOR last message visible (\(message.id.prefix(8))…, idx=\(index)/\(renderedMessages.count))", category: "ChatScrollManager")
                                    }
                                }
                                .onDisappear {
                                    if index == renderedMessages.count - 1 {
                                        Log.debug("SCROLL_ANCHOR last message left the viewport (\(message.id.prefix(8))…)", category: "ChatScrollManager")
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
                        // Breathing room below the last message once the composer itself is
                        // installed via `safeAreaInset`.
                        Color.clear
                            .frame(height: Layout.messageBottomClearance)
                        // Bottom anchor for scrollToBottom.
                        //
                        // Its appearance is the probe that separates the two readings of a blank
                        // chat, which no log has ever been able to do: if this fires while the
                        // screen is empty, the viewport IS at the end of the list and the cells
                        // are not drawing; if it never fires, the offset is somewhere else. One
                        // of those is a rendering bug and the other is a scrolling bug, and we
                        // have been guessing between them since 2026-08-03.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .onAppear {
                                Log.debug("SCROLL_ANCHOR bottom visible (msgs=\(renderedMessages.count), opening=\(scrollManager.isOpening))", category: "ChatScrollManager")
                            }
                            .onDisappear {
                                Log.debug("SCROLL_ANCHOR bottom left the viewport", category: "ChatScrollManager")
                            }
                    }
                    // Top space for floating nav capsule (+ call mini-bar when a call is active).
                    .padding(.top, ChatUIConstants.Shell.scrollContentTopPad + callBarInset)
                    .padding(.horizontal)
                }
                .background(Color.CT.bg) // base under glass
                .accessibilityIdentifier(A11y.Chat.messageList)
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .environment(\.containerWidth, containerWidth)
                .onTapGesture {
                    hideKeyboard()
                }
                .onScrollGeometryChange(for: ChatScrollGeometry.self) { geo in
                    // visibleRect is in content coordinates and already reflects safeAreaInset
                    // (composer). Subtracting maxY from content height is the true "how far up".
                    let distance = geo.contentSize.height - geo.visibleRect.maxY
                    return ChatScrollGeometry(
                        distanceFromBottom: distance,
                        width: geo.containerSize.width,
                        contentFits: geo.contentSize.height <= geo.visibleRect.height + 8,
                        contentHeight: geo.contentSize.height,
                        visibleMinY: geo.visibleRect.minY
                    )
                } action: { old, metrics in
                    scrollManager.updateScrollOffset(
                        distanceFromBottom: metrics.distanceFromBottom,
                        contentFits: metrics.contentFits
                    )
                    // Growth is a re-pin trigger in its own right — media resolves after the
                    // opening pins have already fired (TODO 34, build 579 video).
                    scrollManager.updateContentHeight(metrics.contentHeight)
                    // The blank chat is a *geometry* state and no log has ever shown it: we know
                    // where the messages are and nothing about where the viewport is. One line per
                    // meaningful move answers "was the offset wrong, or were the cells absent".
                    logScrollGeometryIfChanged(from: old, to: metrics)
                    // Ignore zero-width passes during mid-layout; avoid thrashing on sub-pixel noise.
                    if metrics.width > 1, abs(metrics.width - containerWidth) > 0.5 {
                        containerWidth = metrics.width
                    }
                }
                .onAppear {
                    scrollManager.registerProxy(proxy)
                    LocalNotificationManager.shared.clearBadge()
                    scrollManager.hasScrolledToBottom = true
                    // .defaultScrollAnchor(.bottom) + LazyVStack + composer safeAreaInset often
                    // lands the first offset out of range → blank list until a gesture.
                    // Multi-pass non-animated pin covers inset settle and FRC load-more churn.
                    //
                    // Only when there is a transcript to open. On a cold entry there is not: the
                    // store publishes from `viewModel.onViewAppear()`, which runs after this, so
                    // the list is empty here and the opening is armed by the 0 → N change below.
                    // Declaring the opening finished on an empty list is what let the load-more
                    // growth take the animated branch and blank the chat.
                    if !viewModel.messages.isEmpty {
                        scrollManager.beginOpening()
                    }
                }
                .onScrollPhaseChange { _, phase in
                    // A person touching the list outranks the settle timer. `.animating` is our
                    // own corrective pin, so it must not count as a touch.
                    switch phase {
                    case .tracking, .interacting, .decelerating:
                        scrollManager.endOpening()
                    case .idle, .animating:
                        break
                    @unknown default:
                        break
                    }
                }
                .onChange(of: viewModel.messages.count) { oldCount, count in
                    if AppConstants.enableDebugLogging {
                        Log.info("ChatView: messages count changed to \(count)")
                    }

                    // Auto-scroll when new messages arrive — only if the user is at the bottom.
                    // `shouldScrollToBottom` is managed by ChatScrollManager from scroll position,
                    // so this won't fight a user reading history. The whole branch is one decision
                    // (`countChangeAction`) so it can be asserted in a test rather than on a phone.
                    switch ChatScrollManager.countChangeAction(
                        oldCount: oldCount,
                        newCount: count,
                        autoScrollOn: scrollManager.shouldScrollToBottom,
                        searchActive: isSearchActive,
                        isOpening: scrollManager.isOpening
                    ) {
                    case .none:
                        return
                    case .openTranscript:
                        scrollManager.beginOpening()
                    case .correctivePin:
                        // Growth while the layout is still settling — the unprompted load-more
                        // lands here (30 → 50 on every chat entry). Non-animated only.
                        scrollManager.pinToBottomCorrective(delaysMs: [0, 80, 200])
                    case .animatedFollow:
                        let delay = ChatViewConstants.MessageDelay.mediaRender
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(delay))
                            guard scrollManager.shouldScrollToBottom else { return }
                            scrollManager.scrollToBottom(animated: true)
                        }
                    }
                }
                .onChange(of: viewModel.voicePlaybackScrollTarget) { _, target in
                    // Continuous voice playback advanced — bring the now-playing message
                    // into view (centered), then clear the target so a later replay re-scrolls.
                    guard let target else { return }
                    scrollManager.scrollTo(messageId: target, anchor: .center)
                    viewModel.voicePlaybackScrollTarget = nil
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
                        scrollManager.scrollToBottom()
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
                        scrollManager.scrollToBottom()
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

            // Top scrim behind the floating nav capsule so scrolling text doesn't collide with the
            // status bar (clock / signal / battery). Two stacked gradient layers:
            //   1. Progressive blur (bottom): a material frost — which blurs the scroll content
            //      behind it — masked by a top→bottom gradient so the blur fades out lower down.
            //   2. Colour fade (top): a Color.CT.bg → transparent gradient that recolours the grey
            //      frost into the adaptive theme background (black in dark, light base in light) and
            //      fades to clear. Sitting ON TOP of the blur, it kills the frost's greyness while
            //      the blur still softens the text peeking through in the transition band.
            GeometryReader { geo in
                ZStack {
//                    Rectangle()
//                        .fill(.ultraThinMaterial)
//                        .mask(
//                            LinearGradient(
//                                stops: [
//                                    .init(color: .black.opacity(0.95), location: 0),
//                                    .init(color: .black.opacity(0.55), location: 0.55),
//                                    .init(color: .clear, location: 1)
//                                ],
//                                startPoint: .top,
//                                endPoint: .bottom
//                            )
//                        )

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
                }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            messageInputView
                .padding(.horizontal, Layout.composerHorizontalPadding)
                .padding(.bottom, Layout.composerBottomPadding)
                .background(Color.clear)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { _, newHeight in
                    // When the composer grows (voice-recording bar, media preview + quality
                    // chips, reply/edit bar) the ScrollView's bottom safe-area inset changes.
                    // With .defaultScrollAnchor(.bottom) + LazyVStack this can leave the list
                    // blank (content scrolled out of the valid range) until the next manual
                    // scroll — the "chat goes black" symptom. Re-pin to bottom to force a valid
                    // layout, but only when the user was already near the bottom so we don't
                    // yank someone who is reading history.
                    //
                    // The re-pin is NON-animated: an animated scroll interpolates the offset
                    // while the inset is still animating, which keeps the de-materialization
                    // window open (the black flash). The media preview also loads thumbnails
                    // asynchronously, so its height settles in several steps — we pin on this
                    // event and once more after a short delay to catch the final height.
                    guard newHeight.isFinite, newHeight >= 0 else { return }
                    // Ignore sub-point thrash from keyboard/glass; large jumps only (reply bar,
                    // media strip, multiline growth) need a re-pin.
                    let changed = abs(newHeight - composerHeight) > 8
                    composerHeight = newHeight
                    if changed {
                        if scrollManager.shouldScrollToBottom {
                            // Reply/edit/media growth must re-pin without animation (same black-flash path).
                            // Fewer passes — pinTask coalesces concurrent height events.
                            scrollManager.pinToBottomCorrective(delaysMs: [0, 120])
                        } else if let anchorId = (replyingTo ?? viewModel.editingMessage)?.id {
                            // Reading history and starting a reply/edit: the bar grew the bottom
                            // inset. Without a corrective the LazyVStack dematerializes into a
                            // blank list ("chat disappears"). Re-pin around the targeted message
                            // instead of the bottom — keeps it visible without yanking the reader.
                            scrollManager.scrollTo(messageId: anchorId, anchor: .center, animated: false)
                        }
                    }
                }
        }
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

                    // ✅ Enable auto-scroll for new message
                    scrollManager.shouldScrollToBottom = true

                    // Scroll to bottom after sending (longer delay for media)
                    // Use virtual bottom anchor so message is not placed under the input.
                    let sendDelay = ChatViewConstants.MessageDelay.scrollAfterSend
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(sendDelay))
                        scrollManager.scrollToBottom()
                    }
                }
            },
            onSendVoice: { url, duration, waveform in
                viewModel.sendVoiceMessage(url: url, duration: duration, waveform: waveform)
                scrollManager.shouldScrollToBottom = true
                // Scroll using virtual bottom to account for input height.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    scrollManager.scrollToBottom()
                }
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
            if scrollManager.shouldShowScrollToBottomButton && !isEditMode {
                Button {
                    withAnimation(.easeOut(duration: 0.3)) {
                        scrollManager.scrollToBottom() // virtual bottom respects dynamic input padding
                        scrollManager.shouldScrollToBottom = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: CTLayout.callIconSize))
                        .foregroundColor(Color.CT.accent)
                        .frame(width: CTLayout.controlHeight, height: CTLayout.controlHeight)
                        .glassCapsule()
                }
                .padding(.trailing, CTLayout.edgePad)
                .padding(.bottom, ChatUIConstants.Shell.scrollToBottomLift)
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
        scrollManager.scrollTo(messageId: parentId, anchor: .center, animated: true)

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
