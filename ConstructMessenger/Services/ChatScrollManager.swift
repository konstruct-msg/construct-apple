//
//  ChatScrollManager.swift
//  Construct Messenger
//
//  Created by Copilot on 30.01.2026.
//  Refactored from ChatView to isolate scroll management complexity
//

import SwiftUI
import Combine
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Scroll position, auto-scroll, opening pin, and keyboard re-pin for chat transcripts.
///
/// High-frequency geometry stays `@ObservationIgnored` so `onScrollGeometryChange` does not
/// re-render the chat every frame (that loop also produced "tried to update multiple times per frame").
///
/// ## Who owns the viewport
///
/// ``viewportMode`` is the single reading of intent:
/// - ``ViewportMode/opening`` — layout in flight; geometry is noise; only corrective pins
/// - ``ViewportMode/following`` — newest message must stay visible
/// - ``ViewportMode/readingHistory`` — person scrolled up; never yank
///
/// All multi-pass pins go through ``pinToBottom(reason:)`` so delay series live in one table
/// (``PinPolicy``), not scattered call sites.
@MainActor
@Observable
class ChatScrollManager {
    // MARK: - Viewport ownership

    /// Who currently owns the scroll position. Derived from `isOpening` + `shouldScrollToBottom`
    /// so existing flags stay the source of truth for pure decisions / tests.
    enum ViewportMode: Equatable {
        /// Transcript layout is still settling. Geometry must not read as reader intent.
        case opening
        /// Anchored to the newest message (auto-scroll on).
        case following
        /// Person is reading older messages (auto-scroll off).
        case readingHistory
    }

    /// Why a corrective pin series is armed. Each reason maps to one delay series in ``PinPolicy``.
    enum PinReason: String, Equatable, CaseIterable {
        /// First non-empty transcript / re-open with messages already loaded.
        case opening
        /// Count growth while still opening (unprompted load-more 30 → 50).
        case openingGrowth
        /// Content height settled after media / layout thrash.
        case heightSettle
        /// Auto-scroll on but newest row is not materialised.
        case strandedRecover
        /// Composer safe-area inset grew/shrank (reply bar, media strip, multiline).
        case composerInset
        case keyboardShow
        case keyboardHide
    }

    /// Single table of pin delay series. Call sites pass a ``PinReason``, never a raw array.
    enum PinPolicy {
        /// How long height must hold still before a re-pin lands (build 584 flicker).
        static let heightSettleMs: UInt64 = 90

        /// Delay before animated follow after transcript growth (media layout settle).
        static let animatedFollowDelayMs: UInt64 = 100

        /// Opening settle window — after this, geometry is intent again unless the person touched.
        static let openingSettleMs: UInt64 = 600

        static func delays(for reason: PinReason) -> [UInt64] {
            switch reason {
            case .opening:
                // immediate · after first inset · after load-more/FRC · late settle
                return [0, 80, 200, 400]
            case .openingGrowth:
                // Shorter than full opening — growth already inside the opening window.
                return [0, 80, 200]
            case .heightSettle:
                // **No leading 0** — an immediate tick made every intermediate measurement a jump.
                return [heightSettleMs, heightSettleMs + 160]
            case .strandedRecover:
                return [0, 60]
            case .composerInset:
                return [0, 120]
            case .keyboardShow:
                return [150, 280]
            case .keyboardHide:
                return [100, 220]
            }
        }
    }

    // MARK: - Observed UI State
    // Only properties that should invalidate ChatView belong here.

    /// Whether the view should scroll to bottom on next layout
    var shouldScrollToBottom = true

    /// True while the chat is *opening*: from the first non-empty transcript until the
    /// multi-pass pin has settled — or until a person touches the scroll, whichever comes first.
    ///
    /// It exists because during that window the scroll geometry describes a layout in flight, not
    /// a reader. `ChatView` used to hold this as its own `didStabilizeInitialScroll` and armed it
    /// from the wrong evidence: the transcript is empty on first appear (the store publishes from
    /// `onViewAppear`, after the first body pass), and an empty list was read as "the opening
    /// scroll has settled". So by the time the unprompted load-more grew 30 → 50, the opening was
    /// already considered over and the growth took the *animated* branch — an animated scroll
    /// through the composer inset settle, which is what leaves the LazyVStack dematerialized and
    /// the chat blank until a gesture. One authority for "are we still opening", here.
    private(set) var isOpening = false

    /// Derived viewport owner — prefer this when logging or branching on "who owns scroll".
    var viewportMode: ViewportMode {
        if isOpening { return .opening }
        return shouldScrollToBottom ? .following : .readingHistory
    }

    @ObservationIgnored
    private var openingTask: Task<Void, Never>?

    /// Keyboard height when visible
    var keyboardHeight: CGFloat = 0

    /// "Jump to bottom" FAB — only flips when crossing the threshold (not every pixel).
    var shouldShowScrollToBottomButton = false

    // MARK: - High-frequency / private state

    /// Distance from the bottom of the content in points (≈ 0 at bottom; large positive = scrolled up).
    /// Not observed — reading/writing must not invalidate the view every frame.
    @ObservationIgnored
    private(set) var distanceFromBottom: CGFloat = 0

    /// Last measured content height. Not observed — it changes every layout pass.
    @ObservationIgnored
    private(set) var contentHeight: CGFloat = 0

    /// Reference to ScrollViewProxy for programmatic scrolling
    @ObservationIgnored
    private var proxy: ScrollViewProxy?

    /// Cancellables for keyboard notifications
    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    /// Coalesces multi-pass pin / keyboard re-pin so concurrent triggers (composer height +
    /// message count + keyboard) don't stack animated scrolls (black flash / jerky chat).
    @ObservationIgnored
    private var pinTask: Task<Void, Never>?

    @ObservationIgnored
    private var animatedScrollTask: Task<Void, Never>?

    /// Delayed animated follow after count growth (separate from scroll coalesce task).
    @ObservationIgnored
    private var followTask: Task<Void, Never>?

    // MARK: - Thresholds

    private enum Threshold {
        /// Within this many points of the bottom → auto-scroll stays on; FAB hidden.
        static let nearBottom: CGFloat = 60
        /// Need at least this much content below the viewport to show the jump FAB.
        static let showJumpButton: CGFloat = 200
    }

    // MARK: - Back-compat aliases for tests / call sites

    /// How long the height must hold still before a re-pin lands.
    static var heightSettleMs: UInt64 { PinPolicy.heightSettleMs }

    /// The pin series a height change queues. **No leading `0`**.
    static var heightSettleDelaysMs: [UInt64] { PinPolicy.delays(for: .heightSettle) }

    /// Below this a growth is layout noise and re-pinning would be visible churn.
    static let heightRepinThreshold: CGFloat = 24

    // MARK: - Initialization

    init() {
        setupKeyboardObservers()
    }

    // MARK: - Public Methods

    /// Register the ScrollViewProxy for programmatic scrolling
    func registerProxy(_ proxy: ScrollViewProxy) {
        self.proxy = proxy
    }

    /// Scroll to bottom of chat
    /// - Parameters:
    ///   - messageId: Optional specific message ID to scroll to (defaults to "bottom")
    ///   - animated: Animate the scroll. Pass `false` for *corrective* re-pins
    ///     (composer-height changes, first appear). An animated scroll interpolates the
    ///     content offset while the `safeAreaInset` composer is *also* animating its height,
    ///     which can drive the offset outside the valid range and de-materialize the
    ///     `LazyVStack` — the "chat goes black / empty" flash. A non-animated `scrollTo`
    ///     lands a valid offset in a single layout pass and forces the visible cells to
    ///     re-materialize immediately.
    func scrollToBottom(messageId: String = "bottom", animated: Bool = true) {
        guard let proxy = proxy else {
            return
        }

        if animated {
            // Coalesce animated jumps — send/status/FRC storms used to fire 2+ per event.
            animatedScrollTask?.cancel()
            animatedScrollTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let proxy = self.proxy else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(messageId, anchor: .bottom)
                }
                self.shouldScrollToBottom = true
                if self.shouldShowScrollToBottomButton {
                    self.shouldShowScrollToBottomButton = false
                }
                Log.debug("Scrolled to bottom (messageId: \(messageId), animated: true)", category: "ChatScrollManager")
            }
            return
        }

        proxy.scrollTo(messageId, anchor: .bottom)
        shouldScrollToBottom = true
        // Programmatic jump always clears the FAB — don't wait for the next geometry tick.
        if shouldShowScrollToBottomButton {
            shouldShowScrollToBottomButton = false
        }
    }

    /// Arm a multi-pass non-animated pin for a known reason.
    /// Concurrent reasons cancel the previous series (composer + keyboard + opening coalesce).
    func pinToBottom(reason: PinReason, messageId: String = "bottom") {
        let delays = PinPolicy.delays(for: reason)
        Log.debug("PIN arm reason=\(reason.rawValue) delays=\(delays)", category: "ChatScrollManager")
        runPinSeries(delaysMs: delays, messageId: messageId)
    }

    /// Multi-pass non-animated pin. Prefer ``pinToBottom(reason:)`` so delays stay in ``PinPolicy``.
    /// Kept for rare call sites that already chose a series (tests / migration).
    func pinToBottomCorrective(
        delaysMs: [UInt64],
        messageId: String = "bottom"
    ) {
        runPinSeries(delaysMs: delaysMs, messageId: messageId)
    }

    private func runPinSeries(delaysMs: [UInt64], messageId: String) {
        // Prefer non-animated corrective pin over any pending animated jump / follow.
        followTask?.cancel()
        followTask = nil
        animatedScrollTask?.cancel()
        animatedScrollTask = nil
        pinTask?.cancel()
        pinTask = Task { @MainActor [weak self] in
            for (index, ms) in delaysMs.enumerated() {
                if ms > 0 {
                    try? await Task.sleep(for: .milliseconds(ms))
                }
                guard !Task.isCancelled, let self else { return }
                // Both bail-outs are logged: a pin series that silently stopped is
                // indistinguishable from one that ran and missed, and we have spent two builds
                // unable to tell those apart.
                guard self.shouldScrollToBottom else {
                    Log.debug("PIN aborted at tick \(index) — auto-scroll was switched off", category: "ChatScrollManager")
                    return
                }
                // A missing proxy is a *not yet*, not a no: the pin series is armed from
                // `beginOpening` before `ScrollViewReader`'s `onAppear` has handed us the proxy, so
                // tick 0 of every single opening was a silent no-op (8 of 8 in the build-581 log).
                // Skip the tick and keep the series — the later ticks are what it is there for.
                guard self.proxy != nil else {
                    Log.debug("PIN tick \(index) skipped — ScrollViewProxy not registered yet", category: "ChatScrollManager")
                    continue
                }
                Log.debug(
                    "PIN tick \(index) (+\(ms)ms) → \(messageId), mode=\(self.viewportMode), contentHeight=\(Int(self.contentHeight))pt fromBottom=\(Int(self.distanceFromBottom))",
                    category: "ChatScrollManager"
                )
                self.scrollToBottom(messageId: messageId, animated: false)
                // First tick is often a no-op if LazyVStack has not produced the anchor yet.
                if index == 0 {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard !Task.isCancelled, self.shouldScrollToBottom else { return }
                    self.scrollToBottom(messageId: messageId, animated: false)
                }
            }
        }
    }

    // MARK: - Opening window

    /// Start the opening window: pin to the bottom and treat scroll geometry as layout noise
    /// until it settles. Called when the transcript first becomes non-empty (and on a re-appear
    /// that already has one) — never on an empty transcript, which says nothing has opened yet.
    ///
    /// Auto-scroll is forced back on here on purpose: whatever the geometry reported for the
    /// blank first layout was not a reading position, and letting it survive into the opening
    /// meant every corrective pin bailed at its own `shouldScrollToBottom` guard.
    func beginOpening(settleAfterMs: UInt64 = PinPolicy.openingSettleMs) {
        openingTask?.cancel()
        isOpening = true
        shouldScrollToBottom = true
        if shouldShowScrollToBottomButton { shouldShowScrollToBottomButton = false }
        pinToBottom(reason: .opening)
        openingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(settleAfterMs))
            guard !Task.isCancelled else { return }
            self?.isOpening = false
        }
    }

    /// End the opening window early. A person touching the list outranks the settle timer:
    /// someone who enters a chat and immediately swipes up must not be pinned back down.
    func endOpening() {
        openingTask?.cancel()
        openingTask = nil
        if isOpening { isOpening = false }
    }

    /// Apply the pure ``countChangeAction`` decision — one entry for transcript length changes.
    func handleTranscriptCountChange(oldCount: Int, newCount: Int, searchActive: Bool) {
        switch Self.countChangeAction(
            oldCount: oldCount,
            newCount: newCount,
            autoScrollOn: shouldScrollToBottom,
            searchActive: searchActive,
            isOpening: isOpening
        ) {
        case .none:
            return
        case .openTranscript:
            beginOpening()
        case .correctivePin:
            pinToBottom(reason: .openingGrowth)
        case .animatedFollow:
            followNewestAnimated()
        }
    }

    /// Ordinary new message on a settled layout — delayed animated follow.
    /// Uses its own task so the delay is not cancelled by `scrollToBottom`'s coalesce task.
    func followNewestAnimated() {
        followTask?.cancel()
        followTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(PinPolicy.animatedFollowDelayMs))
            guard !Task.isCancelled, let self, self.shouldScrollToBottom else { return }
            self.scrollToBottom(animated: true)
        }
    }

    /// Scroll to a specific message
    func scrollTo(messageId: String, anchor: UnitPoint = .center, animated: Bool = true) {
        guard let proxy = proxy else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(messageId, anchor: anchor)
            }
        } else {
            proxy.scrollTo(messageId, anchor: anchor)
        }

        Log.debug("Scrolled to message: \(messageId)", category: "ChatScrollManager")
    }

    /// Update scroll metrics (from `onScrollGeometryChange`).
    ///
    /// - Parameter distanceFromBottom: points of content **below** the visible rect
    ///   (`contentSize.height - visibleRect.maxY`). ≈ 0 at bottom; large when scrolled up.
    ///   Prefer this over `contentOffset + containerHeight - contentSize` — that formula
    ///   ignores `contentInsets` from the composer `safeAreaInset`, so with keyboard/composer
    ///   open the chat looked "at bottom" while the metric stayed ≤ −200 and the FAB stuck on.
    /// - Parameter contentFits: content shorter than the viewport → nothing to jump to.
    ///
    /// A height change is a *measurement of a layout in flight*, not an event to act on. Build 584
    /// opened one chat and reported seven of them inside a second — 91 → 596 → 4524 → 4755 → 4673
    /// → 5948 → 5210 → 4673, ending where it had been three steps earlier. Pinning on each one
    /// scrolled the transcript seven times: the flicker. Only where it lands is worth a scroll.
    ///
    /// Successive changes cancel each other (`pinToBottom` cancels the pending series), so a
    /// burst costs exactly one scroll.
    func updateContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let previous = contentHeight
        contentHeight = height
        guard Self.shouldRepinForHeightChange(
            previousHeight: previous,
            currentHeight: height,
            autoScrollOn: shouldScrollToBottom,
            isOpening: isOpening
        ) else { return }
        Log.debug(
            "Content \(height > previous ? "grew" : "shrank") \(Int(previous)) → \(Int(height))pt while pinned — re-pin queued (mode=\(viewportMode))",
            category: "ChatScrollManager"
        )
        pinToBottom(reason: .heightSettle)
    }

    /// Whether the newest message is currently materialised. Fed by the last row's
    /// `onAppear`/`onDisappear`; `true` until the transcript first reports otherwise, so an empty
    /// or not-yet-rendered list never reads as stranded.
    @ObservationIgnored private(set) var isLastMessageVisible = true

    /// Report the newest message appearing or leaving, and recover if auto-scroll is anchored to a
    /// place the transcript has vacated. See `shouldRecoverStrandedViewport`.
    func noteLastMessageVisible(_ visible: Bool, searchActive: Bool) {
        isLastMessageVisible = visible
        guard Self.shouldRecoverStrandedViewport(
            lastMessageVisible: visible,
            autoScrollOn: shouldScrollToBottom,
            isOpening: isOpening,
            searchActive: searchActive
        ) else { return }
        Log.debug(
            "SCROLL_RECOVER: mode=\(viewportMode) but newest message off screen (contentHeight=\(Int(contentHeight))pt fromBottom=\(Int(distanceFromBottom))) — re-pinning",
            category: "ChatScrollManager"
        )
        pinToBottom(reason: .strandedRecover)
    }

    /// Composer inset changed. Re-pin when following; when reading history and a reply/edit is
    /// open, caller should scroll to that message instead.
    func noteComposerHeightChanged() {
        guard shouldScrollToBottom else { return }
        pinToBottom(reason: .composerInset)
    }

    func updateScrollOffset(distanceFromBottom distance: CGFloat, contentFits: Bool = false) {
        guard distance.isFinite else { return }

        distanceFromBottom = distance

        let next = Self.flags(
            current: ScrollFlags(autoScroll: shouldScrollToBottom, showJumpButton: shouldShowScrollToBottomButton),
            distanceFromBottom: distance,
            contentFits: contentFits,
            keyboardVisible: isKeyboardVisible,
            isOpening: isOpening
        )
        if next.autoScroll != shouldScrollToBottom {
            shouldScrollToBottom = next.autoScroll
        }
        if next.showJumpButton != shouldShowScrollToBottomButton {
            shouldShowScrollToBottomButton = next.showJumpButton
        }
    }

    // MARK: - Pure decisions

    struct ScrollFlags: Equatable {
        var autoScroll: Bool
        var showJumpButton: Bool
    }

    /// What the two observed flags become for a given scroll geometry.
    ///
    /// The one rule that is not just a threshold: **while the chat is opening, geometry may turn
    /// auto-scroll back ON but never OFF.** A large `distanceFromBottom` means "the person scrolled
    /// up" only once there is a settled layout to scroll within; during the opening it is equally
    /// the signature of an offset that has not landed yet — and reading it as intent switched off
    /// the auto-scroll that the corrective pin then refused to perform, which is a chat that stays
    /// blank until the user swipes. Same for the jump FAB, which flashed on over an empty list.
    static func flags(
        current: ScrollFlags,
        distanceFromBottom distance: CGFloat,
        contentFits: Bool,
        keyboardVisible: Bool,
        isOpening: Bool
    ) -> ScrollFlags {
        if contentFits {
            return ScrollFlags(autoScroll: true, showJumpButton: false)
        }

        let nearBottom = distance <= Threshold.nearBottom
        let farUp = distance >= Threshold.showJumpButton

        // Keyboard / composer-height animation produces transient distances.
        // Never latch the FAB ON while the keyboard is up; still allow hide + near-bottom.
        if keyboardVisible {
            guard nearBottom else { return current }
            return ScrollFlags(autoScroll: true, showJumpButton: false)
        }

        if isOpening {
            return ScrollFlags(
                autoScroll: nearBottom ? true : current.autoScroll,
                showJumpButton: false
            )
        }

        return ScrollFlags(autoScroll: nearBottom, showJumpButton: farUp)
    }

    /// A list anchored to the bottom must stay anchored when the content grows under it — and
    /// message *count* is only one of the two ways it grows. The other is height: a media bubble
    /// is laid out small and becomes tall when its image resolves, and nothing re-pinned for that.
    ///
    /// Build 579 (video 2026-08-05 18:22, blank chat): the corrective pins land at 0/80/200/400ms,
    /// the images resolve later, and the transcript settles ~470pt lower than where the pins put
    /// it — the viewport is left over a region the content has since vacated.
    ///
    /// **Either direction.** Build 583: pin at 5792pt, settle at 3952pt, viewport 922pt past end.
    static func shouldRepinForHeightChange(
        previousHeight: CGFloat,
        currentHeight: CGFloat,
        autoScrollOn: Bool,
        isOpening: Bool
    ) -> Bool {
        guard autoScrollOn || isOpening else { return false }
        guard previousHeight > 0 else { return false }   // first measurement is not a change
        return abs(currentHeight - previousHeight) >= heightRepinThreshold
    }

    /// Whether the transcript is anchored to the bottom but the newest message is not on screen.
    ///
    /// Auto-scroll makes exactly one promise — *the newest message is visible*. Stated as
    /// visibility rather than distance: an inset chat has a legitimately negative
    /// `distanceFromBottom`, so any numeric cutoff would move with the composer.
    ///
    /// Not applied while opening — the corrective pin series owns that window — nor while search
    /// is active, where the transcript is deliberately elsewhere.
    static func shouldRecoverStrandedViewport(
        lastMessageVisible: Bool,
        autoScrollOn: Bool,
        isOpening: Bool,
        searchActive: Bool
    ) -> Bool {
        guard autoScrollOn, !isOpening, !searchActive else { return false }
        return !lastMessageVisible
    }

    /// What a change in transcript length should do to the scroll position.
    enum CountChangeAction: Equatable {
        case none
        /// The transcript went from nothing to something — this is the chat opening.
        case openTranscript
        /// Growth during the opening window: non-animated pin only.
        case correctivePin
        /// Ordinary new message on a settled layout.
        case animatedFollow
    }

    /// `openTranscript` deliberately ignores `autoScrollOn`: the flag describes where a reader
    /// was in a transcript that did not exist yet, so it cannot be evidence about this one.
    static func countChangeAction(
        oldCount: Int,
        newCount: Int,
        autoScrollOn: Bool,
        searchActive: Bool,
        isOpening: Bool
    ) -> CountChangeAction {
        guard newCount > 0, !searchActive else { return .none }
        if oldCount == 0 { return .openTranscript }
        guard autoScrollOn else { return .none }
        if isOpening { return .correctivePin }
        // Never follow a count *drop* (FRC thrash): that path animated to bottom while the
        // LazyVStack dematerialized → black flash.
        guard newCount > oldCount else { return .none }
        return .animatedFollow
    }

    /// Reset scroll state (e.g., when switching chats)
    func reset() {
        pinTask?.cancel()
        pinTask = nil
        animatedScrollTask?.cancel()
        animatedScrollTask = nil
        followTask?.cancel()
        followTask = nil
        openingTask?.cancel()
        openingTask = nil
        isOpening = false
        shouldScrollToBottom = true
        shouldShowScrollToBottomButton = false
        distanceFromBottom = 0
        contentHeight = 0
        isLastMessageVisible = true
        proxy = nil

        Log.debug("ChatScrollManager reset", category: "ChatScrollManager")
    }

    // MARK: - Keyboard Handling

    private func setupKeyboardObservers() {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { notification in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
            }
            .sink { [weak self] height in
                self?.keyboardHeight = height
                // Corrective pin only — animated scroll during keyboard animation
                // dematerializes LazyVStack (empty chat flash).
                guard let self else { return }
                if self.shouldShowScrollToBottomButton {
                    self.shouldShowScrollToBottomButton = false
                }
                if self.shouldScrollToBottom {
                    self.pinToBottom(reason: .keyboardShow)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.keyboardHeight = 0
                // After keyboard dismisses, re-enable auto-scroll and clear any FAB that
                // latched during the keyboard geometry thrash.
                self.shouldScrollToBottom = true
                self.shouldShowScrollToBottomButton = false
                self.pinToBottom(reason: .keyboardHide)
            }
            .store(in: &cancellables)
        #endif
    }
}

// MARK: - Computed Properties

extension ChatScrollManager {
    /// Whether keyboard is currently visible
    var isKeyboardVisible: Bool {
        keyboardHeight > 0
    }
}
