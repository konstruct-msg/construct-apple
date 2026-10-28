//
//  ChatView+Transcript.swift
//  Construct Messenger
//
//  The transcript container wiring, composer and scroll handling, split out of ChatView.swift.
//

// iOS only: the Desktop target excludes ChatView.swift / AccountSettingsView.swift.
#if os(iOS)
import SwiftUI
import CoreData
import UniformTypeIdentifiers

extension ChatView {
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
    func transcript(_ renderedMessages: [TranscriptEntry]) -> some View {
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
                .padding(.top, topBarInset + ChatUIConstants.Shell.scrollContentTopPad + callBarInset)
                .padding(.horizontal)
                .coordinateSpace(name: Self.transcriptContentSpace)
                .environment(\.containerWidth, containerWidth)
            }
            // The legacy path clears the badge from `registerTranscriptProxy`, which this container
            // never calls — it has no `ScrollViewReader`, so `onProxyReady` does not exist here.
            // Opening a chat therefore left the badge standing for the whole owned-path build.
            .onAppear { LocalNotificationManager.shared.syncBadge() }
            // Under the bar's glass, as a SwiftUI scroll view goes on its own; `topBarInset` keeps
            // the first message clear of it.
            .ignoresSafeArea(.container, edges: .top)
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
    private func legacyTranscript(_ renderedMessages: [TranscriptEntry]) -> some View {
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
    var composer: some View {
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
        LocalNotificationManager.shared.syncBadge()
        // .defaultScrollAnchor(.bottom) + LazyVStack + composer safeAreaInset often lands the
        // first offset out of range → blank list until a gesture. Multi-pass non-animated pin
        // covers inset settle and FRC load-more churn.
        //
        // Only when there is a transcript to open. On a cold entry there is not: the store
        // publishes from `viewModel.onViewAppear()`, which runs after this, so the list is empty
        // here and the opening is armed by the 0 → N change instead. Declaring the opening
        // finished on an empty list is what let load-more growth take the animated branch and
        // blank the chat.
        viewport.noteTranscriptAppeared(messageCount: viewModel.entries.count)
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
        viewport.updateGeometry(metrics, messageCount: viewModel.entries.count)
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
        // `viewModel.entries`: it is what the rows are built from, so it is the only one whose
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
    private func loadMoreSentinel(_ renderedMessages: [TranscriptEntry]) -> some View {
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
    private func transcriptRows(_ renderedMessages: [TranscriptEntry]) -> some View {
                // Messages in oldest-first order (ScrollView anchored to bottom via .defaultScrollAnchor)
                ForEach(Array(renderedMessages.enumerated()), id: \.element.id) { index, message in
                    VStack(spacing: 0) {
                        ObservedTranscriptRow(entry: message) { row in MessageBubble(
                            message: row,
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
                            onTapSticker: { ref in
                                stickerPackPreview = StickerPackPreviewItem(pack: ref.pack)
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
                            },
                            onForward: { msg in startForward([msg]) }
                        ) }
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
                        .opacity(replyFocusOpacity(for: message.id))
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

    func attemptLoadOlderHistory() {
        guard viewport.shouldLoadOlderHistory(
            isSearchActive: isSearchActive,
            isLoadingMore: viewModel.isLoadingMore,
            hasMoreMessages: viewModel.hasMoreMessages
        ) else { return }
        viewModel.loadMoreMessages(trigger: .indicatorAppeared)
    }
}
#endif
