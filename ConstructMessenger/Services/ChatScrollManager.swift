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
    // MARK: - Logging

    /// High-frequency geometry / anchor probes (`SCROLL_GEO`, `SCROLL_ANCHOR`, pin ticks).
    /// **Off by default even in DEBUG** — build 586 exported 259 `SCROLL_GEO` + 50+ anchor lines
    /// in 4.5 minutes while the useful signal was the rare `PIN arm` / `SCROLL_RECOVER`. Flip on
    /// for a live blank-chat investigation; do not leave on when collecting thermal logs.
    static var verboseGeometryLogging = false

    /// Probe-level scroll diagnostics. No-op unless ``verboseGeometryLogging`` is on.
    static func logGeometry(_ message: @autoclosure () -> String) {
        guard verboseGeometryLogging else { return }
        Log.debug(message(), category: "ChatScrollManager")
    }

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
        /// Count growth while still opening (media / FRC — not load-more; that is gated off).
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

        /// Two `ChatScrollManager` instances (SwiftUI re-create) and/or a double-delivered
        /// `keyboardWillHide` within ~20ms both used to arm a pin series. One series is enough.
        static let keyboardPinCoalesceSeconds: TimeInterval = 0.2

        /// Composer height settles in steps (reply bar → media strip → async thumbnails). Each
        /// step used to arm a full `[0, 120]` series; one series covers the burst if we re-arm at
        /// most once per this window. Longer than a single pin tick so intermediate layouts share
        /// the first series' delayed pass.
        static let composerInsetCoalesceSeconds: TimeInterval = 0.2

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
    /// scroll has settled". Growth during that window (media, FRC) must stay non-animated — an
    /// animated scroll through the composer inset settle dematerializes the LazyVStack and leaves
    /// the chat blank until a gesture. One authority for "are we still opening", here. Load-more
    /// itself is refused while this is true (`shouldLoadOlderHistory`).
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

    /// A finger is on the list (or the list is still carrying that finger's momentum).
    ///
    /// Fed by `onScrollPhaseChange`, and the reason `flags` can tell "the keyboard inset is
    /// animating" from "the keyboard has been up for a minute while someone reads". `.animating`
    /// is deliberately **not** dragging: that phase is our own corrective pin, and counting it
    /// would let a pin's own motion be read as the person's intent — the exact confusion
    /// `endOpening` already avoids on the same signal.
    @ObservationIgnored private(set) var isUserDragging = false

    /// Which scroll phases prove a **finger is on the list right now**.
    ///
    /// `.decelerating` was in this set for one build and caused visible flicker (device log
    /// 2026-08-14, 18:39). Within 150 ms of `KEYBOARD_TRACE: will SHOW` — before the keyboard pin's
    /// own first tick — the log shows `PIN aborted at tick 0 — auto-scroll was switched off`,
    /// followed by four `Scrolled to bottom (animated: true)`. Nobody scrolled in those 150 ms; the
    /// keyboard was rising and the content settling under it, and SwiftUI reported that settling as
    /// deceleration. Read as intent, it unfroze `flags` mid-animation, switched auto-scroll off,
    /// flashed the FAB on, and the next follow switched it all back — which is the flicker.
    ///
    /// So the set is only the phases that require a touch: `.tracking` (finger down, dragging) and
    /// `.interacting` (finger down, e.g. grabbing momentum). Deceleration is content in motion, and
    /// content in motion is exactly what this signal must not trust — the same reason `.animating`
    /// is excluded, since that one is our own corrective pin.
    ///
    /// Losing `.decelerating` costs nothing: the freeze **preserves** whatever the drag established
    /// (`testDragEndedWithKeyboardUp_preservesReadingHistory`), so the verdict reached while the
    /// finger was down survives the coast.
    static func isDragPhase(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting:
            return true
        case .decelerating, .idle, .animating:
            return false
        @unknown default:
            return false
        }
    }

    /// Whether a phase means the person has taken the transcript over from the opening settle
    /// timer. Wider than ``isDragPhase(_:)`` on purpose, and unchanged since before that existed:
    /// once a flick is coasting the opening is over, even though the coast is not evidence about
    /// where the person wants to be.
    static func endsOpening(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .tracking, .interacting, .decelerating:
            return true
        case .idle, .animating:
            return false
        @unknown default:
            return false
        }
    }

    /// Single entry for scroll phase. Both hosts call this from `onScrollPhaseChange`.
    func noteScrollPhase(_ phase: ScrollPhase) {
        // Two questions, two answers, one phase. "Is a finger down" gates the keyboard freeze;
        // "has the person taken over" ends the opening window. Conflating them is what put
        // `.decelerating` into the first set and produced the flicker.
        isUserDragging = Self.isDragPhase(phase)
        if Self.endsOpening(phase) {
            endOpening()
        }
    }

    /// Process-wide last keyboard pin — coalesces duplicate NC deliveries and multi-manager
    /// observers (build 586: one willShow → two PIN arm keyboardShow).
    @ObservationIgnored private static var lastKeyboardPinReason: PinReason?
    @ObservationIgnored private static var lastKeyboardPinUptime: TimeInterval = 0

    /// Per-manager last composer-inset pin. Not process-wide: two chats must not share a window.
    @ObservationIgnored private var lastComposerInsetPinUptime: TimeInterval = 0

    // MARK: - High-frequency / private state

    /// Distance from the bottom of the content in points (≈ 0 at bottom; large positive = scrolled up).
    /// Not observed — reading/writing must not invalidate the view every frame.
    @ObservationIgnored
    private(set) var distanceFromBottom: CGFloat = 0

    /// Last measured content height. Not observed — it changes every layout pass.
    @ObservationIgnored
    private(set) var contentHeight: CGFloat = 0

    /// Top of the viewport in content coordinates. With `contentHeight` and `distanceFromBottom`
    /// this is enough to say how much transcript is actually on screen — see
    /// `visibleContentFraction`.
    @ObservationIgnored
    private(set) var visibleMinY: CGFloat = 0

    /// Whether ``visibleMinY`` above holds a measurement rather than its initial value.
    ///
    /// It is the only honest reading of "is the viewport near the top of the content", and until
    /// the first geometry tick there is no such reading — only a `0` that happens to satisfy every
    /// near-top comparison. Device log 2026-08-14: the sentinel's `onAppear` runs *before* the
    /// transcript count ever changes, so `isOpening` is still false and the load-more gate fell
    /// through to `visibleMinY <= nearTop`, which `0 <= 120` answered yes. Every chat open widened
    /// 30 → 50 unasked (TODO 34), five times in one short session.
    ///
    /// The comment on ``Threshold/nearTop`` says bottom-anchored entry is refused because
    /// `visibleMinY ≫ this`. That is true of a *measured* viewport and false of an unmeasured one,
    /// and nothing distinguished the two.
    @ObservationIgnored private(set) var hasMeasuredViewportTop = false

    /// Content shorter than the viewport. Kept so load-more policy can fill a short window after
    /// opening without waiting for a second sentinel `onAppear` (which may never come).
    @ObservationIgnored
    private(set) var contentFits = false

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

    /// Not private: `nearBottom` is what separates "anchored, and the transcript vanished" from
    /// "the reader scrolled up", so the stranded-viewport tests assert against the same number the
    /// flags use rather than a copy of it.
    enum Threshold {
        /// Within this many points of the bottom → auto-scroll stays on; FAB hidden.
        static let nearBottom: CGFloat = 60
        /// Need at least this much content below the viewport to show the jump FAB.
        static let showJumpButton: CGFloat = 200
        /// Viewport top is within this many points of the content top → infinite-scroll may fire.
        /// Slack covers top padding + the 1pt sentinel / ProgressView so a real "scrolled to oldest"
        /// is not lost to sub-pixel noise, while bottom-anchored entry (visibleMinY ≫ this) is refused.
        static let nearTop: CGFloat = 120
    }

    // MARK: - Back-compat aliases for tests / call sites

    /// How long the height must hold still before a re-pin lands.
    static var heightSettleMs: UInt64 { PinPolicy.heightSettleMs }

    /// The pin series a height change queues. **No leading `0`**.
    static var heightSettleDelaysMs: [UInt64] { PinPolicy.delays(for: .heightSettle) }

    /// Below this a growth is layout noise and re-pinning would be visible churn.
    ///
    /// `nonisolated` because it is a constant, not state: the class is `@MainActor`, so without
    /// this the threshold inherits main-actor isolation and `ChatView.Layout.geometryLogThreshold`
    /// — a nested enum's static, initialized off the main actor — cannot read it. That is an error
    /// under the Swift 6 language mode, and the tempting fix is to write `24` again in `ChatView`.
    /// Two copies of the same cutoff is exactly what this property exists to prevent: the log
    /// threshold and the re-pin threshold must move together or the log stops describing the
    /// decision it is there to explain.
    nonisolated static let heightRepinThreshold: CGFloat = 24

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
                    Self.logGeometry("PIN tick \(index) skipped — ScrollViewProxy not registered yet")
                    continue
                }
                Self.logGeometry(
                    "PIN tick \(index) (+\(ms)ms) → \(messageId), mode=\(self.viewportMode), contentHeight=\(Int(self.contentHeight))pt fromBottom=\(Int(self.distanceFromBottom))"
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
    // `updateContentHeight` and its re-pin are gone as of build 585, and the deletion is the fix.
    //
    // Re-pinning on a height change is **circular in a lazy list**: a pin changes which cells are
    // materialised, which changes the measured content height, which triggers another pin. Build
    // 585 shows the loop running unbounded — 631 re-pins and 115 recoveries in one session, the
    // height oscillating 2645 ↔ 3000 ↔ 3151 forever:
    //
    //     Content shrank 3000 → 2645  re-pin queued
    //     last message left the viewport
    //     SCROLL_RECOVER — re-pinning        ← fromBottom=-91: we were AT the bottom
    //     Content grew 2645 → 3151    re-pin queued
    //     Content shrank 3151 → 3000  re-pin queued …
    //
    // 583 made the height a trigger to catch a collapse the pins had outrun; 584 debounced it,
    // which slowed the loop without breaking it, because each pin produces its new height after
    // the debounce has already fired. The height is a *consequence* of the scroll position, not an
    // independent signal about it, so no amount of filtering makes it a safe trigger.
    //
    // `shouldRecoverStrandedViewport` covers what the height rule was reaching for — it names the
    // end state (the viewport is off the transcript) instead of the intermediate measurements —
    // and it is not circular, because a correction that works stops satisfying it.

    /// Whether the newest message is currently materialised. Fed by the last row's
    /// `onAppear`/`onDisappear`; `true` until the transcript first reports otherwise, so an empty
    /// or not-yet-rendered list never reads as stranded.
    @ObservationIgnored private(set) var isLastMessageVisible = true

    /// When the newest message went off screen, or nil while it is on screen.
    @ObservationIgnored private var newestHiddenSince: Date?
    @ObservationIgnored private var absenceRecheckTask: Task<Void, Never>?

    /// Report the newest message appearing or leaving, and recover if auto-scroll is anchored to a
    /// place the transcript has vacated. See `shouldRecoverStrandedViewport`.
    func noteLastMessageVisible(_ visible: Bool, searchActive: Bool, now: Date = Date()) {
        isLastMessageVisible = visible
        if visible {
            newestHiddenSince = nil
            absenceRecheckTask?.cancel()
            absenceRecheckTask = nil
        } else if newestHiddenSince == nil {
            newestHiddenSince = now
            // The callback is an edge: nothing fires again while the message simply stays away,
            // so the persistence half of the rule needs its own look back. Build 587 sat blank
            // for 4 s and then 26 s without a single further callback.
            absenceRecheckTask?.cancel()
            absenceRecheckTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(UInt64(Self.newestMessageAbsenceGrace * 1000) + 50))
                guard !Task.isCancelled, let self, !self.isLastMessageVisible else { return }
                self.evaluateStrandedViewport(searchActive: searchActive)
            }
        }
        evaluateStrandedViewport(searchActive: searchActive, now: now)
    }

    private func evaluateStrandedViewport(searchActive: Bool, now: Date = Date()) {
        let fraction = Self.visibleContentFraction(
            contentHeight: contentHeight,
            visibleMinY: visibleMinY,
            distanceFromBottom: distanceFromBottom
        )
        let hiddenFor = newestHiddenSince.map { now.timeIntervalSince($0) } ?? 0
        guard Self.shouldRecoverStrandedViewport(
            lastMessageVisible: isLastMessageVisible,
            newestHiddenFor: hiddenFor,
            visibleContentFraction: fraction,
            distanceFromBottom: distanceFromBottom,
            contentFits: contentFits,
            autoScrollOn: shouldScrollToBottom,
            isOpening: isOpening,
            searchActive: searchActive
        ) else { return }
        Log.debug(
            "SCROLL_RECOVER: mode=\(viewportMode), newest off screen for \(String(format: "%.1f", hiddenFor))s, \(Int(fraction * 100))% of the viewport shows transcript (contentHeight=\(Int(contentHeight))pt fromBottom=\(Int(distanceFromBottom)) fits=\(contentFits)) — re-pinning",
            category: "ChatScrollManager"
        )
        newestHiddenSince = nil
        pinToBottom(reason: .strandedRecover)
    }

    /// Composer inset changed. Re-pin when following; when reading history and a reply/edit is
    /// open, caller should scroll to that message instead.
    ///
    /// Coalesces multi-step height settles (reply bar + media strip + thumbnails) so one series
    /// covers the burst — same shape as keyboard pin coalesce, per manager.
    func noteComposerHeightChanged(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard shouldScrollToBottom else { return }
        guard Self.shouldArmComposerInsetPin(
            now: now,
            lastTime: lastComposerInsetPinUptime
        ) else {
            Self.logGeometry("PIN arm skipped (composer coalesce)")
            return
        }
        lastComposerInsetPinUptime = now
        pinToBottom(reason: .composerInset)
    }

    func updateScrollOffset(
        distanceFromBottom distance: CGFloat,
        contentFits: Bool = false,
        contentHeight newContentHeight: CGFloat? = nil,
        visibleMinY newVisibleMinY: CGFloat? = nil
    ) {
        guard distance.isFinite else { return }

        distanceFromBottom = distance
        self.contentFits = contentFits
        if let newContentHeight, newContentHeight.isFinite, newContentHeight > 0 {
            contentHeight = newContentHeight
        }
        if let newVisibleMinY, newVisibleMinY.isFinite {
            visibleMinY = newVisibleMinY
            hasMeasuredViewportTop = true
        }

        let next = Self.flags(
            current: ScrollFlags(autoScroll: shouldScrollToBottom, showJumpButton: shouldShowScrollToBottomButton),
            distanceFromBottom: distance,
            contentFits: contentFits,
            keyboardVisible: isKeyboardVisible,
            userIsDragging: isUserDragging,
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

    /// Whether the infinite-scroll sentinel may widen the transcript window.
    ///
    /// The defect this closes (TODO 34 / `load_more_unprompted`): `LazyVStack` materialises the
    /// top sentinel on first layout even when the scroll is bottom-anchored, so every chat entry
    /// used to prepend a batch (30 → 50) while the opening pin was still landing. Opening already
    /// stopped that growth from taking the animated branch; this stops the fetch itself.
    ///
    /// `isOpening` was supposed to be the whole guard, and on device it never got the chance:
    /// the sentinel's `onAppear` fires *before* the transcript count first changes, so
    /// `beginOpening` has not run yet and `isOpening` is still false. What actually admitted the
    /// fetch was `visibleMinY`, holding its initial `0` because no geometry tick had happened —
    /// and `0 <= nearTop` is true. `hasMeasuredViewportTop` is what separates "the viewport is at
    /// the top" from "nobody has looked yet".
    ///
    /// Allowed only when:
    /// - the viewport top has been measured at least once, and
    /// - not opening (layout is settled enough to read intent), and
    /// - either the viewport is at the oldest edge (`visibleMinY` near 0), or the whole transcript
    ///   fits on screen (short window of a longer history — keep filling until it can scroll).
    static func shouldLoadOlderHistory(
        hasMeasuredViewportTop: Bool,
        isOpening: Bool,
        contentFits: Bool,
        visibleMinY: CGFloat,
        isSearchActive: Bool,
        isLoadingMore: Bool,
        hasMoreMessages: Bool
    ) -> Bool {
        guard hasMoreMessages, !isLoadingMore, !isSearchActive else { return false }
        // Before the first tick `contentFits` is also just its initial `false`, so this guard
        // sits above both branches on purpose: neither input means anything yet.
        guard hasMeasuredViewportTop else { return false }
        if isOpening { return false }
        if contentFits { return true }
        return visibleMinY <= Threshold.nearTop
    }

    /// Instance view of ``shouldLoadOlderHistory(isOpening:contentFits:visibleMinY:isSearchActive:isLoadingMore:hasMoreMessages:)``
    /// over the last geometry tick.
    func shouldLoadOlderHistory(
        isSearchActive: Bool,
        isLoadingMore: Bool,
        hasMoreMessages: Bool
    ) -> Bool {
        Self.shouldLoadOlderHistory(
            hasMeasuredViewportTop: hasMeasuredViewportTop,
            isOpening: isOpening,
            contentFits: contentFits,
            visibleMinY: visibleMinY,
            isSearchActive: isSearchActive,
            isLoadingMore: isLoadingMore,
            hasMoreMessages: hasMoreMessages
        )
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
        userIsDragging: Bool,
        isOpening: Bool
    ) -> ScrollFlags {
        if contentFits {
            return ScrollFlags(autoScroll: true, showJumpButton: false)
        }

        let nearBottom = distance <= Threshold.nearBottom
        let farUp = distance >= Threshold.showJumpButton

        // Keyboard / composer-height animation produces transient distances, so geometry alone is
        // not intent while the inset moves. But this branch was written as "while the keyboard is
        // *visible*" and it means "while the keyboard is *animating*" — and the difference is a
        // whole reading session.
        //
        // Device log 2026-08-14, 18:00:45 → 18:01:29: `will SHOW` with no matching `will HIDE`,
        // then six load-more batches (30 → 158 messages) as the person scrolled up. The FAB never
        // came back — `keyboardWillShow` had cleared it and `return current` could never set it
        // again — and `autoScroll` could not switch off either, so the count change at 158 read as
        // "we are following" and animated them back to the newest message. They had scrolled 128
        // messages up. It is the same yank `keyboardHideAction` closed, entered by a different
        // door: not "the keyboard was dismissed", but "the keyboard was never dismissed".
        //
        // A finger on the list outranks the heuristic — the rule this file already applies to the
        // opening window via `endOpening`. While the person drags, geometry IS intent, keyboard or
        // not. When the drag ends the freeze resumes and simply preserves whatever the drag
        // established, which is the desired behaviour and needs no timer.
        if keyboardVisible && !userIsDragging {
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

    /// Height is not a re-pin trigger. Build 585: pin→materialise→new height→pin looped
    /// unbounded (631 re-pins). ``shouldRecoverStrandedViewport`` names the end state instead.
    /// ``PinReason/heightSettle`` stays in ``PinPolicy`` so a future caller cannot reintroduce
    /// a leading-0 tick; nothing in production arms it.

    /// Whether the transcript is anchored to the bottom but the newest message is not on screen.
    ///
    /// Auto-scroll makes exactly one promise — *the newest message is visible*. Stated as
    /// visibility rather than distance: an inset chat has a legitimately negative
    /// `distanceFromBottom`, so any numeric cutoff would move with the composer.
    ///
    /// Not applied while opening — the corrective pin series owns that window — nor while search
    /// is active, where the transcript is deliberately elsewhere.
    /// Below this share of the viewport showing transcript, the screen reads as empty and the
    /// position is wrong whatever the row callbacks say. A **ratio**, not a point count, so it is
    /// immune to the composer and keyboard insets — those are a fraction of a screen, never half of
    /// one. Blank chat (build 583): content 3952, viewport [3942…4874] → 1 % covered. Healthy, at
    /// rest, composer inset only: ~90 %.
    static let strandedCoverageFloor: CGFloat = 0.5

    /// How long the newest message must stay off screen before its absence counts as a strand
    /// rather than a re-materialisation flicker.
    ///
    /// Measured, not guessed. Build 585 (the false-positive run): 120 absence episodes, 112 of
    /// them shorter than a second. Build 587 (the blank chat): 4 s and 26 s. A second cleanly
    /// separates the flicker from the failure.
    static let newestMessageAbsenceGrace: TimeInterval = 1.0

    /// Two independent ways to be stranded, because the two witnesses are each blind to one of
    /// them — and the 585→587 sequence is what proved it:
    ///
    /// - **The viewport is off the transcript** (coverage below the floor). Geometry sees this
    ///   and the row callback may not. Build 583: content 3952, viewport [3942…4874], 1 % covered.
    ///
    /// - **The newest message is not rendered, persistently.** The row callback sees this and
    ///   geometry *cannot*, which is the 587 regression: `content=4961 viewport=[4113…5045]
    ///   fromBottom=-84` reads as 91 % covered while the screen is empty, because a `LazyVStack`
    ///   reports height for rows it has not rendered. Content height was the very thing lying,
    ///   so a metric derived from it could only agree with the lie. The chat filled the moment
    ///   the keyboard forced a re-layout — the giveaway that the rows, not the position, were
    ///   missing.
    ///
    /// So neither witness gets a veto; each fires on what it can actually see. What keeps the row
    /// callback from re-creating the 585 storm is duration, not arbitration: `onDisappear` flaps
    /// for a frame or two during re-materialisation and cannot sustain an absence.
    static func shouldRecoverStrandedViewport(
        lastMessageVisible: Bool,
        newestHiddenFor: TimeInterval,
        visibleContentFraction: CGFloat,
        distanceFromBottom: CGFloat,
        contentFits: Bool,
        autoScrollOn: Bool,
        isOpening: Bool,
        searchActive: Bool
    ) -> Bool {
        guard autoScrollOn, !isOpening, !searchActive else { return false }
        // `autoScrollOn` is not proof that the viewport is at the bottom. While the keyboard is up
        // the flags deliberately latch (`flags(current:…)` returns `current` unchanged rather than
        // read a transient distance), so a person who scrolls up to read history keeps auto-scroll
        // on. Build 588 fired twice on exactly that, both a second before `KEYBOARD_TRACE: will
        // HIDE`:
        //
        //     newest off screen for 1.1s, 94% of the viewport shows transcript
        //         (contentHeight=3147pt fromBottom=2378) — re-pinning
        //     newest off screen for 1.1s, 100% …    (contentHeight=3181pt fromBottom=626)
        //
        // 2378pt above the bottom with the screen full of transcript: the newest message is off
        // screen because the reader put it there. Recovering yanked them to the end mid-read —
        // the misfire that is worse than the bug. The blank chat this rule exists for sits at
        // `fromBottom=-84`; anchored is negative or near zero, never hundreds of points up.
        guard distanceFromBottom <= Threshold.nearBottom else { return false }
        // The newest row being on screen is proof the chat is not blank, and it outranks any
        // ratio: a short transcript legitimately covers very little of the viewport. Coverage
        // answers *where the viewport is*, never *whether anything is drawn*.
        guard !lastMessageVisible else { return false }
        // Coverage answers *where the viewport is*. When the transcript is shorter than the
        // viewport there is nowhere else for it to be, so the ratio stops meaning anything and
        // becomes just the fill level — which is legitimately low for a short chat. Build 593,
        // eleven messages, right after sending an album:
        //
        //     newest off screen for 0.0s, 42% of the viewport shows transcript
        //         (contentHeight=798pt fromBottom=-538) — re-pinning
        //
        // 798pt of content against a viewport half again as tall, and `fromBottom` negative
        // because there is nothing to scroll. The newest row simply had not been laid out yet.
        // The `distanceFromBottom <= nearBottom` guard cannot catch this: -538 passes it easily.
        //
        // The duration branch still applies. A newest row missing for a full second is a blank
        // chat whether or not the content fits, and that is the failure this rule exists for.
        let coverageIsMeaningful = !contentFits
        return (coverageIsMeaningful && visibleContentFraction < strandedCoverageFloor)
            || newestHiddenFor >= newestMessageAbsenceGrace
    }

    /// The share of the viewport actually showing transcript, 0…1.
    ///
    /// `1` when the geometry is not yet known — an unmeasured layout must never read as stranded.
    static func visibleContentFraction(
        contentHeight: CGFloat,
        visibleMinY: CGFloat,
        distanceFromBottom: CGFloat
    ) -> CGFloat {
        let visibleMaxY = contentHeight - distanceFromBottom
        let viewportHeight = visibleMaxY - visibleMinY
        guard viewportHeight > 0, contentHeight > 0 else { return 1 }
        let overlap = min(contentHeight, visibleMaxY) - max(0, visibleMinY)
        guard overlap > 0 else { return 0 }
        return min(1, overlap / viewportHeight)
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

    // MARK: - Keyboard Handling

    /// Whether another keyboard pin of the same reason was armed too recently.
    /// Pure so the 586 double-arm (two managers × one notification) can be asserted without UIKit.
    static func shouldArmKeyboardPin(
        reason: PinReason,
        now: TimeInterval,
        lastReason: PinReason?,
        lastTime: TimeInterval,
        coalesceWindow: TimeInterval = PinPolicy.keyboardPinCoalesceSeconds
    ) -> Bool {
        guard reason == .keyboardShow || reason == .keyboardHide else { return true }
        if lastReason == reason, (now - lastTime) < coalesceWindow {
            return false
        }
        return true
    }

    /// Whether a composer-inset height change should arm a new pin series.
    /// Pure so multi-step media/reply settles can be asserted without SwiftUI geometry.
    static func shouldArmComposerInsetPin(
        now: TimeInterval,
        lastTime: TimeInterval,
        coalesceWindow: TimeInterval = PinPolicy.composerInsetCoalesceSeconds
    ) -> Bool {
        // lastTime == 0 means never armed on this manager (ProcessInfo uptime is > 0 after launch).
        if lastTime > 0, (now - lastTime) < coalesceWindow {
            return false
        }
        return true
    }

    /// True when this instance should treat a willShow height as a new keyboard event
    /// (not a same-frame redelivery).
    static func shouldApplyKeyboardShow(newHeight: CGFloat, previousHeight: CGFloat) -> Bool {
        guard newHeight.isFinite, newHeight > 0 else { return false }
        if previousHeight > 0, abs(newHeight - previousHeight) < 1 {
            return false
        }
        return true
    }

    /// Whether raising the keyboard may take away the "jump to newest" button.
    ///
    /// It used to, unconditionally, to drop a latch that keyboard geometry thrash might have
    /// produced. That also took the way back from someone reading history who merely tapped the
    /// composer, and once cleared the `keyboardVisible` freeze in ``flags(current:distanceFromBottom:contentFits:keyboardVisible:userIsDragging:isOpening:)``
    /// could never light it again — the FAB stayed gone for the rest of the session
    /// (device log 2026-08-14, 18:00:45 onward).
    ///
    /// The thrash it guarded against can no longer latch anything: with no finger on the list that
    /// branch returns `current` unchanged. So the answer is yes only for someone already at the
    /// tail, where the button is false anyway and this is belt and braces.
    static func shouldClearJumpButtonOnKeyboardShow(isFollowing: Bool, jumpButtonVisible: Bool) -> Bool {
        isFollowing && jumpButtonVisible
    }

    /// What a `keyboardWillHide` is allowed to do to the viewport.
    enum KeyboardHideAction: Equatable {
        /// Touch nothing. The person is reading history, or the keyboard was never up.
        case ignore
        /// We were already following — the pin may re-land the tail. `shouldScrollToBottom`
        /// is **not** written: in this branch it is already `true` by construction.
        case keepFollowing
    }

    /// Dismissing the keyboard is not a request to leave history.
    ///
    /// Until 2026-08-14 the hide observer ran, unconditionally and *above* its own
    /// `guard wasVisible`:
    ///
    /// ```swift
    /// self.shouldScrollToBottom = true
    /// self.shouldShowScrollToBottomButton = false
    /// guard wasVisible else { return }
    /// ```
    ///
    /// Two defects in three lines. A reader who had scrolled up, tapped the composer and
    /// dismissed the keyboard was dragged to the newest message — build 588 closed the same yank
    /// for a *visible* keyboard via stranded-recover and left hide untouched. And because the
    /// writes sat above the guard, the system's second hide delivery (~20 ms later, which the
    /// comment on that guard explicitly describes) re-forced auto-scroll even when the first
    /// delivery had correctly done nothing.
    ///
    /// `.opening` counts as following: that window belongs to the corrective pin series, and a
    /// person who has not touched anything has not left the tail.
    ///
    /// This is a decision over two scalars precisely so the yank can be pinned by a test —
    /// `testKeyboardHide_whileReadingHistory_doesNotYank` and
    /// `testKeyboardHide_duplicateDelivery_doesNotForceFollowing`. The second is not redundant:
    /// without it, moving the writes back above the guard stays green.
    ///
    /// **NOT COVERED BY A TEST: that the observer below actually asks this function.** The
    /// decision is verified by mutation; the wiring is not, because reaching it means a live
    /// `NotificationCenter` and UIKit. Someone could reintroduce an unconditional
    /// `shouldScrollToBottom = true` in the sink and every test here would stay green.
    ///
    /// What answers it on device: scroll up in a chat, tap the composer, dismiss the keyboard.
    /// With `verboseGeometryLogging` on, a correct build logs **no** `PIN arm reason=keyboardHide`
    /// and the transcript does not move. A regression shows that line and jumps to the newest
    /// message. The two-sim stand cannot answer it — it drives no software keyboard dismissal.
    static func keyboardHideAction(mode: ViewportMode, keyboardWasVisible: Bool) -> KeyboardHideAction {
        guard keyboardWasVisible else { return .ignore }
        switch mode {
        case .following, .opening:
            return .keepFollowing
        case .readingHistory:
            return .ignore
        }
    }

    private func tryArmKeyboardPin(reason: PinReason) {
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.shouldArmKeyboardPin(
            reason: reason,
            now: now,
            lastReason: Self.lastKeyboardPinReason,
            lastTime: Self.lastKeyboardPinUptime
        ) else {
            Log.debug(
                "PIN arm skipped (keyboard coalesce) reason=\(reason.rawValue)",
                category: "ChatScrollManager"
            )
            return
        }
        Self.lastKeyboardPinReason = reason
        Self.lastKeyboardPinUptime = now
        pinToBottom(reason: reason)
    }

    private func setupKeyboardObservers() {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { notification in
                (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height
            }
            .sink { [weak self] height in
                guard let self else { return }
                let previous = self.keyboardHeight
                self.keyboardHeight = height
                // Corrective pin only — animated scroll during keyboard animation
                // dematerializes LazyVStack (empty chat flash).
                //
                // Clearing the FAB here used to be unconditional, to drop a latch that keyboard
                // geometry thrash might have produced. It also took away the way back from
                // someone reading history who merely tapped the composer — and once cleared, the
                // `keyboardVisible` freeze in `flags` could never light it again. The thrash it
                // guarded against cannot latch anything now: without a finger on the list that
                // branch returns `current` unchanged. So clear it only for a follower, where it
                // is already false and this is belt and braces.
                if Self.shouldClearJumpButtonOnKeyboardShow(
                    isFollowing: self.shouldScrollToBottom,
                    jumpButtonVisible: self.shouldShowScrollToBottomButton
                ) {
                    self.shouldShowScrollToBottomButton = false
                }
                guard self.shouldScrollToBottom else { return }
                guard Self.shouldApplyKeyboardShow(newHeight: height, previousHeight: previous) else {
                    return
                }
                self.tryArmKeyboardPin(reason: .keyboardShow)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                // Second hide on the same instance (system double-delivery ~20ms later) is a
                // no-op — and that now holds for the whole block, not just the pin. The two
                // flag writes used to sit above this evidence and re-fired on the redelivery.
                let wasVisible = self.keyboardHeight > 0
                self.keyboardHeight = 0
                // Decide before mutating: `viewportMode` is derived from `shouldScrollToBottom`,
                // so writing it first would make the decision read its own output.
                let action = Self.keyboardHideAction(
                    mode: self.viewportMode,
                    keyboardWasVisible: wasVisible
                )
                guard action == .keepFollowing else { return }
                // Only for someone already at the tail: clear a FAB that latched during the
                // keyboard geometry thrash. A reader in history keeps theirs — it is their way back.
                self.shouldShowScrollToBottomButton = false
                self.tryArmKeyboardPin(reason: .keyboardHide)
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
