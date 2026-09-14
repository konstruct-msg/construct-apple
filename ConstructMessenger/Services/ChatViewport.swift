//
//  ChatViewport.swift
//  Construct Messenger
//
//  Who owns the transcript's scroll position. Replacement for `ChatScrollManager` on the
//  owned-inset path — see `decisions/chat-viewport-owned-inset.md` and
//  `client/ios/CHAT_VIEWPORT_MIGRATION.md` (PR-3).
//
//  ## What is different, in one paragraph
//
//  `ChatScrollManager` corrects the scroll *offset*: seven pin reasons, four delay series and a
//  stranded-recovery, all ending in the same `proxy.scrollTo("bottom")`. The failure it was built
//  against is not an offset — device log 2026-08-19 reports `fromBottom=-83` with 90 % coverage
//  while the screen is empty, which is the viewport correctly at the end of a list whose rows a
//  `LazyVStack` has not drawn. Scrolling to where you already are cannot draw them, so the
//  correction could never reach its own success condition; build 585 ran 631 re-pins and 115
//  recoveries in one session doing exactly that.
//
//  So this type does not own a remedy for it. The remedy is the eager stack the container gets in
//  the next step, where there is nothing left to not-materialise. What remains here is policy:
//  which of two modes the viewport is in, and when. `.defaultScrollAnchor(.bottom)` keeps the tail
//  in `following` on its own — measured in the PR-0 spike: growing the composer pad by 40pt at the
//  bottom leaves `distanceFromBottom` at 0 with no `scrollTo` at all.
//
//  ## Two modes, no third
//
//  There is no `opening`. `ChatScrollManager.isOpening` was a 600 ms timer standing in for "the
//  layout has not settled", and a timer cannot know that. `layoutPrimed` replaces it with the fact
//  it was reaching for: the tail is on screen. Until then geometry may turn following ON and never
//  OFF.
//
//  ## Not wired up yet
//
//  Step 1 of PR-3 is this file alone, so the pure decisions can be tested and mutated before any
//  view depends on them. `ChatView` still runs `ChatScrollManager`.
//

import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class ChatViewport {

    // MARK: - Mode

    /// Who the viewport belongs to right now. Two values on purpose — see the file comment.
    enum Mode: Equatable {
        /// The newest message must stay visible. The scroll anchor owns this, not a `scrollTo`.
        case following
        /// The person is reading older messages. Never yank.
        case readingHistory
    }

    /// What a change in transcript length should do.
    ///
    /// `.preservePrependAnchor` is deliberately absent. It belongs with the handler that consumes
    /// it, in one commit — a producer with no consumer is a defect (`AGENTS.md`), and the PR-0
    /// spike showed `.scrollPosition(id:)` does not survive a prepend, so that handler needs a
    /// mechanism this codebase does not have yet.
    enum CountChangeAction: Equatable {
        case none
        /// Nothing → something: the chat is opening.
        case openTranscript
        /// Append while following. A no-op by design: the anchor holds the tail.
        case follow
    }

    enum KeyboardHideAction: Equatable {
        case ignore
        /// Was following: the anchor and the pad handle it. Do **not** write `mode`.
        case keepFollowing
    }

    struct ScrollFlags: Equatable {
        var following: Bool
        var showJumpButton: Bool
    }

    enum Threshold {
        /// Within this many points of the bottom → following stays on; FAB hidden.
        static let nearBottom: CGFloat = 60
        /// Need at least this much content below the viewport to show the jump FAB.
        static let showJumpButton: CGFloat = 200
        /// Viewport top within this many points of the content top → load-more may fire.
        static let nearTop: CGFloat = 120
        /// Below this, an inset move is layout noise rather than a settle in progress.
        static let padNoise: CGFloat = 8
        /// How far *past* the end of the content still counts as the tail.
        ///
        /// Build 583 sat at −922 with 1 % of the viewport showing transcript: past-the-end is not
        /// the tail, and a bare `distance <= nearBottom` accepts it. An inset chat is legitimately
        /// a little negative, which is what the slack is for.
        static let pastEndSlack: CGFloat = 200
        /// Share of the viewport that must show transcript for the tail to count as landed.
        static let strandedCoverageFloor: CGFloat = 0.5
        /// Quiet geometry ticks before a missing tail is reported rather than waited out.
        static let missingTailStableTicks: Int = 3
    }

    // MARK: - Observed state

    private(set) var mode: Mode = .following
    private(set) var showJumpButton = false

    /// The tail has landed on screen. Closed by that fact, never by the ingredients.
    ///
    /// `count > 0 && pad > 0` looks like the same thing and is not. The composer is on screen from
    /// the first frame, so the pad is measured *before* the store publishes; a 0 → N in the same
    /// turn would make both true while `.defaultScrollAnchor(.bottom)` has not applied and media
    /// have not reached their final height. Geometry would then be free to read a large
    /// `distanceFromBottom` as "the person scrolled up" and refuse to follow — which is
    /// `didStabilizeInitialScroll = true` on an empty first appear, the defect this whole
    /// migration exists to retire.
    private(set) var layoutPrimed = false

    /// Reply-peek only: an incoming message must not pull the transcript while a parent is held
    /// on screen. Does **not** change `mode`.
    private(set) var incomingFollowSuppressed = false

    /// Monotonic token for "take me to the newest message". Observed, so a change reaches the
    /// scroll container through the ordinary view update.
    ///
    /// This exists because on this path there is no `ScrollViewProxy` to command. One is created by
    /// `ChatTranscriptContainer`, which is the *legacy* container; `ChatTranscriptScrollView` has no
    /// `ScrollViewReader` and never calls `onProxyReady`, so `registerProxy` was never reached and
    /// `proxy` was nil for the life of every chat. `followExplicitly` ended in
    /// `proxy?.scrollTo("bottom")` and therefore did nothing at all: on device the control cleared
    /// its own flag, slid out on its transition, and slid back when the next geometry tick
    /// recomputed the same distance — reported as "the button moves a few millimetres right and
    /// returns".
    ///
    /// A counter rather than a `Bool`, so two taps are two lands and nothing has to reset it.
    private(set) var landRequest: Int = 0

    /// The row a guest scroll is trying to reach, or nil when none is pending.
    ///
    /// Observed, and read by `ChatView` to decide which rows measure themselves. That is the whole
    /// mechanism: a row reports its position only while something needs it, so naming a target here
    /// is what makes the target measurable. One extra reporter at a time, on the same reasoning that
    /// keeps thirty of them off the transcript — a per-frame cost for a number nobody reads.
    private(set) var scrollTargetId: String?

    /// Monotonic token for the guest scroll, twin of `landRequest`.
    ///
    /// Separate from `scrollTargetId` because the same row may be asked for twice — a voice message
    /// replayed, a search re-run against the same first hit — and an id that has not changed is not
    /// a second request.
    private(set) var scrollRequest: Int = 0

    /// Vertical placement the pending guest scroll asked for: 0 top, 0.5 centre, 1 bottom.
    @ObservationIgnored private(set) var scrollTargetAnchor: CGFloat = 0.5

    /// An inset is moving, so geometry is not intent this tick.
    ///
    /// Replaces the 600 ms opening timer and the keyboard notifications with the measurement
    /// itself: set while any of composer height, bottom safe area or container height moved by at
    /// least `Threshold.padNoise`, cleared on the next tick where all three are quiet.
    ///
    /// **"Tick" means every geometry sample, and that is a requirement on the caller.** Until
    /// 2026-08-21 `noteInsetDelta` was reached only from call sites that had themselves noticed a
    /// change, so a quiet tick was never delivered and this latched `true` on the first
    /// container-height measurement of every chat and stayed there. `flags` then forced
    /// `showJumpButton` off for the life of the screen and refused to let geometry stop following,
    /// which pinned `mode` at `.following` and handed `TranscriptOffsetPolicy` a `.land` on every
    /// content-height change. One unwired latch, and both the missing jump control and the
    /// transcript snapping back to the bottom mid-drag.
    ///
    /// `testInsetLatch_clearsOnTheNextQuietTick` covered the unit and passed throughout: it makes
    /// the third call itself. Nothing tested that anyone would.
    private(set) var insetSettling = false

    /// The row whose movement stands in for the reader's, or nil while following (the tail needs
    /// no measuring stick).
    ///
    /// Not "the message on screen". `TranscriptOffsetPolicy.hold` moves the offset by however far
    /// this row moved, so what it needs is a row that moves exactly as much as the reader does —
    /// which is any row at or below the top of the viewport, and on the owned path is bound to the
    /// **oldest rendered message at the moment following stopped**. That choice is exact for the
    /// two things that actually change the content: a prepend inserts entirely above it, and an
    /// append entirely below it.
    ///
    /// **Pinned at the transition, never re-derived.** Re-reading "the oldest message" each pass
    /// would pick a different row after every load-more, and the coordinator's shift is the
    /// difference between two samples of one row — two rows make it noise.
    ///
    /// Cleared by ``followExplicitly()`` and by opening a transcript; re-bound by a guest scroll
    /// inside history, which is equally valid as a stick.
    ///
    /// Measured limit (PR-0, 2026-08-19): a row above the reader *growing* — media finishing its
    /// decode between this row and the viewport — moves the reader without moving the stick. Not
    /// mitigated, and not mitigable with one reporter.
    var positionId: String?

    // MARK: - High-frequency state
    // Not observed: these change every layout pass and must not invalidate the view.

    @ObservationIgnored private(set) var distanceFromBottom: CGFloat = 0
    @ObservationIgnored private(set) var contentHeight: CGFloat = 0
    @ObservationIgnored private(set) var visibleMinY: CGFloat = 0
    @ObservationIgnored private(set) var contentFits = false

    /// Whether a person has touched the transcript this visit. A touch outranks every heuristic
    /// here, and it is also what makes a quiet-tick count meaningful.
    @ObservationIgnored private(set) var userInteracted = false

    /// Consecutive geometry ticks with no inset movement and no touch.
    @ObservationIgnored private(set) var stableQuietTicks = 0

    @ObservationIgnored private var lastComposerHeight: CGFloat = 0
    @ObservationIgnored private var lastSafeAreaBottom: CGFloat = 0
    @ObservationIgnored private var lastContainerHeight: CGFloat = 0
    @ObservationIgnored private var hasInsetBaseline = false

    // MARK: - Pure decisions
    // Everything a test needs to reach lives here. Instance methods below are the wiring that
    // applies them, and hold no policy of their own.

    /// What the two flags become for a given geometry.
    ///
    /// The one rule that is not a threshold: **while an inset is moving or the tail has not
    /// landed, geometry may turn following ON but never OFF.** A large `distanceFromBottom` means
    /// "the person scrolled up" only once there is a settled layout to have scrolled within;
    /// before that it is equally the signature of an offset that has not arrived. Reading it as
    /// intent switched following off, and then every correction refused to run — a chat that stays
    /// blank until someone swipes.
    static func flags(
        current: ScrollFlags,
        distanceFromBottom distance: CGFloat,
        contentFits: Bool,
        insetSettling: Bool,
        layoutPrimed: Bool
    ) -> ScrollFlags {
        if contentFits {
            return ScrollFlags(following: true, showJumpButton: false)
        }

        let nearBottom = distance <= Threshold.nearBottom
        let farUp = distance >= Threshold.showJumpButton

        if insetSettling || !layoutPrimed {
            return ScrollFlags(
                following: nearBottom ? true : current.following,
                showJumpButton: false
            )
        }
        return ScrollFlags(following: nearBottom, showJumpButton: farUp)
    }

    /// The share of the viewport actually showing transcript, 0…1.
    ///
    /// `1` when the geometry is not yet known — an unmeasured layout must never read as stranded.
    ///
    /// On a lazy stack this was a witness that could only agree with a lie: `contentSize` counts
    /// rows that were never drawn, so 91 % coverage was reported over an empty screen. On an eager
    /// stack the height is honest and so is this, which is why it survives the migration while the
    /// recovery built on top of it does not.
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

    /// Has the tail landed?
    ///
    /// Stated as two conditions because `distance <= nearBottom` alone accepts build 583:
    /// content 3952, viewport [3942…4874], `distanceFromBottom = −922`, 1 % covered. That is the
    /// viewport past the end of the content, which is the blank chat, not the tail.
    static func shouldPrime(
        alreadyPrimed: Bool,
        messageCount: Int,
        contentHeight: CGFloat,
        distanceFromBottom: CGFloat,
        contentFits: Bool,
        visibleContentFraction: CGFloat
    ) -> Bool {
        if alreadyPrimed { return true }
        guard messageCount > 0 else { return false }
        // Nothing has been laid out yet. `contentFits` is `contentSize <= viewport`, which an
        // unmeasured stack satisfies with a height of zero — so on the stand (2026-08-19) the very
        // first tick of a 40-message chat read as landed, and load-more went 30 → 40 unasked before
        // a single row existed. Same shape as `visibleMinY == 0` meaning "nobody has looked".
        guard contentHeight > 0 else { return false }
        // A transcript shorter than the viewport has nowhere else to be, so coverage stops being a
        // position and becomes a fill level — legitimately low for a short chat (build 593).
        if contentFits { return true }
        let nearTail = distanceFromBottom <= Threshold.nearBottom
            && distanceFromBottom > -Threshold.pastEndSlack
        return nearTail && visibleContentFraction >= Threshold.strandedCoverageFloor
    }

    /// Whether a landing that never happened is worth an ERROR.
    ///
    /// Deliberately not armed on the first 0 → N tick. The transcript arrives before the anchor
    /// applies and before media reach their heights, so an alert there would fire on every healthy
    /// cold open. It needs quiet: no inset moving, nobody touching, for
    /// ``Threshold/missingTailStableTicks`` ticks in a row.
    ///
    /// Landing is asked of ``shouldPrime(alreadyPrimed:messageCount:distanceFromBottom:contentFits:visibleContentFraction:)``
    /// rather than restated here, so the alert and the state can never disagree about what a
    /// landed tail is.
    static func shouldReportMissingTail(
        stableQuietTicks: Int,
        insetSettling: Bool,
        messageCount: Int,
        contentHeight: CGFloat,
        padReady: Bool,
        userInteracted: Bool,
        alreadyPrimed: Bool,
        distanceFromBottom: CGFloat,
        contentFits: Bool,
        visibleContentFraction: CGFloat
    ) -> Bool {
        guard messageCount > 0, padReady, !insetSettling, !userInteracted, !alreadyPrimed else {
            return false
        }
        guard stableQuietTicks >= Threshold.missingTailStableTicks else { return false }
        return !shouldPrime(
            alreadyPrimed: false,
            messageCount: messageCount,
            contentHeight: contentHeight,
            distanceFromBottom: distanceFromBottom,
            contentFits: contentFits,
            visibleContentFraction: visibleContentFraction
        )
    }

    /// Whether the transcript window may widen at the oldest edge.
    ///
    /// `layoutPrimed` is the whole guard, including for `contentFits`. An unprimed short chat that
    /// prefetches is TODO 34 by another name: every cold entry widened 30 → 50 unasked, because
    /// an eager sentinel is in the tree from the first frame and "the content fits" is true before
    /// anything has landed.
    static func shouldLoadOlderHistory(
        layoutPrimed: Bool,
        contentFits: Bool,
        visibleMinY: CGFloat,
        isSearchActive: Bool,
        isLoadingMore: Bool,
        hasMoreMessages: Bool
    ) -> Bool {
        guard hasMoreMessages, !isLoadingMore, !isSearchActive else { return false }
        guard layoutPrimed else { return false }
        if contentFits { return true }
        return visibleMinY <= Threshold.nearTop
    }

    /// What a change in transcript length should do to the scroll position.
    ///
    /// `.follow` is a no-op at the call site by design — the anchor holds the tail, and a
    /// `scrollTo` on every append is what produced the animated jumps. It is still a named action
    /// rather than `.none` because "we are following and the transcript grew" and "nothing to do"
    /// are different facts, and only one of them belongs in the yank metric's denominator.
    static func countChangeAction(
        oldCount: Int,
        newCount: Int,
        mode: Mode,
        searchActive: Bool,
        incomingFollowSuppressed: Bool
    ) -> CountChangeAction {
        guard newCount > 0, !searchActive else { return .none }
        if incomingFollowSuppressed { return .none }
        // 0 → N ignores mode on purpose: whatever the geometry said about a blank list was not a
        // reading position.
        if oldCount == 0 { return .openTranscript }
        guard mode == .following else { return .none }
        // An FRC drop shortens the transcript. That is not an append and must not follow.
        guard newCount > oldCount else { return .none }
        return .follow
    }

    /// What the keyboard going away should do.
    ///
    /// Never `mode = .following`. The old path wrote that above its own `wasVisible` guard, so a
    /// duplicated system notification re-forced it and dragged a reader of history to the tail.
    static func keyboardHideAction(mode: Mode, keyboardWasVisible: Bool) -> KeyboardHideAction {
        guard keyboardWasVisible else { return .ignore }
        switch mode {
        case .following:      return .keepFollowing
        case .readingHistory: return .ignore
        }
    }

    // MARK: - Wiring

    /// Never called on this path — `ChatTranscriptScrollView` has no `ScrollViewReader` to make a
    /// proxy from. A required member of the protocol shared with the legacy owner until PR-4, so it
    /// stays; it stores nothing, because since 2026-08-22 nothing here reads a proxy. `scrollTo`
    /// was the last reader and it did not work: the proxy was nil for the life of every chat.
    func registerProxy(_ proxy: ScrollViewProxy) {}

    /// One geometry tick.
    func updateScrollOffset(
        distanceFromBottom distance: CGFloat,
        contentFits: Bool,
        contentHeight newContentHeight: CGFloat,
        visibleMinY newVisibleMinY: CGFloat,
        messageCount: Int
    ) {
        guard distance.isFinite else { return }

        distanceFromBottom = distance
        self.contentFits = contentFits
        if newContentHeight.isFinite, newContentHeight > 0 { contentHeight = newContentHeight }
        if newVisibleMinY.isFinite { visibleMinY = newVisibleMinY }

        let fraction = Self.visibleContentFraction(
            contentHeight: contentHeight,
            visibleMinY: visibleMinY,
            distanceFromBottom: distance
        )

        // Primed before flags: the tick that lands the tail is also the first tick whose geometry
        // may be read as intent. Doing it the other way round spends one tick reading a settled
        // layout under unprimed rules.
        if Self.shouldPrime(
            alreadyPrimed: layoutPrimed,
            messageCount: messageCount,
            contentHeight: contentHeight,
            distanceFromBottom: distance,
            contentFits: contentFits,
            visibleContentFraction: fraction
        ) {
            layoutPrimed = true
        }

        stableQuietTicks = (insetSettling || userInteracted) ? 0 : stableQuietTicks + 1

        let next = Self.flags(
            current: ScrollFlags(following: mode == .following, showJumpButton: showJumpButton),
            distanceFromBottom: distance,
            contentFits: contentFits,
            insetSettling: insetSettling,
            layoutPrimed: layoutPrimed
        )
        apply(next)
    }

    /// One entry for all three inset sources, because they latch the same thing.
    ///
    /// Three independent latches was the shape that let a keyboard-driven safe-area change look
    /// like a settled layout while the composer height happened to be still.
    func noteInsetDelta(composer: CGFloat, safeAreaBottom: CGFloat, containerHeight: CGFloat) {
        defer {
            lastComposerHeight = composer
            lastSafeAreaBottom = safeAreaBottom
            lastContainerHeight = containerHeight
            hasInsetBaseline = true
        }
        // The first report is a baseline, not a move. Without this every chat opens "settling"
        // against zeros and the first real tick is spent clearing it.
        guard hasInsetBaseline else { return }

        let moved = abs(composer - lastComposerHeight) >= Threshold.padNoise
            || abs(safeAreaBottom - lastSafeAreaBottom) >= Threshold.padNoise
            || abs(containerHeight - lastContainerHeight) >= Threshold.padNoise
        insetSettling = moved
        if moved { stableQuietTicks = 0 }
    }

    /// The container put the tail on screen. The one place `layoutPrimed` closes on the owned
    /// path: it is a fact reported by whoever did it, not a threshold guessed from geometry.
    ///
    /// `shouldPrime` stays — it is still the landing predicate the missing-tail metric asks, and
    /// it is what the lazy path uses. Here the container knows, so it says.
    func noteTailLanded() {
        guard !layoutPrimed else { return }
        layoutPrimed = true
    }

    /// The person has taken the transcript over. Outranks the landing heuristic in both
    /// directions: it primes the layout and it lets geometry switch following off.
    func noteUserInteraction() {
        userInteracted = true
        layoutPrimed = true
        stableQuietTicks = 0
    }

    /// Bind the measuring stick, at the moment following stops.
    ///
    /// Deliberately not a `mode` writer. Its predecessor (`bindHistoryPosition`) set both, and
    /// shipped with no callers at all — so `positionId` was never anything but nil, no row ever
    /// installed the reporter that measures it, `anchorShift` was always nil, and
    /// `TranscriptOffsetPolicy`'s whole `.readingHistory` branch could only return `.none`. The
    /// prepend rule this migration exists for had no input.
    ///
    /// A no-op when a stick is already bound: the pin has to survive the prepends it exists to
    /// measure. `followExplicitly` and `openTranscript` are what release it.
    func bindAnchorRow(_ messageId: String?) {
        guard mode == .readingHistory, positionId == nil, let messageId else { return }
        positionId = messageId
    }

    func setIncomingFollowSuppressed(_ suppressed: Bool) {
        guard incomingFollowSuppressed != suppressed else { return }
        incomingFollowSuppressed = suppressed
    }

    func handleTranscriptCountChange(oldCount: Int, newCount: Int, searchActive: Bool) {
        switch Self.countChangeAction(
            oldCount: oldCount,
            newCount: newCount,
            mode: mode,
            searchActive: searchActive,
            incomingFollowSuppressed: incomingFollowSuppressed
        ) {
        case .none:
            return
        case .openTranscript:
            mode = .following
            positionId = nil
            showJumpButton = false
            // `layoutPrimed` stays where it is: opening a transcript is not landing one.
        case .follow:
            // Intentionally nothing. `.defaultScrollAnchor(.bottom)` keeps the tail, measured in
            // the PR-0 spike. A `scrollTo` here is the animated jump this migration removes.
            return
        }
    }

    func noteKeyboardHidden(wasVisible: Bool) {
        switch Self.keyboardHideAction(mode: mode, keyboardWasVisible: wasVisible) {
        case .ignore, .keepFollowing:
            // Neither branch writes `mode`. `.keepFollowing` is the anchor's job and is named so a
            // future edit has to argue with the name rather than quietly add an assignment.
            return
        }
    }

    /// Take the reader to the newest message: the jump control, sending, and dismissing search.
    func followExplicitly() {
        mode = .following
        positionId = nil
        showJumpButton = false
        landRequest &+= 1
    }

    /// Guest scrolls: search result, peek parent, voice now-playing.
    ///
    /// **Never assigns `mode`, and does not need to.** Landing on a row away from the tail makes
    /// the next geometry report say so — `flags` reads `following` straight off the distance — so
    /// the mode and the jump control follow from where the viewport actually is rather than from an
    /// assignment made in advance. A guest scroll inside history also re-binds the held row, so the
    /// anchor rule cannot pull the reader back off the row they just asked for.
    ///
    /// The move itself is a *request*, not an action, because the destination is not known here:
    /// only a row that installs a reporter has a position, and the target installs one because this
    /// method names it. `ChatTranscriptScrollView` performs the move on the layout pass where that
    /// measurement first exists. Same shape as `landRequest`, for the same reason — the offset
    /// belongs to the pass that produced the content it lands in.
    ///
    /// Until 2026-08-22 this ended in `proxy?.scrollTo`, and the owned path has no
    /// `ScrollViewProxy`. Every jump was a no-op: tapping a reply, a search hit or a playing voice
    /// message did nothing at all.
    func scrollTo(messageId: String, anchor: UnitPoint = .center, animated: Bool = true) {
        if mode == .readingHistory { positionId = messageId }
        scrollTargetId = messageId
        scrollTargetAnchor = anchor.y
        scrollRequest &+= 1
    }

    /// The container moved the offset onto the target, or the row left the transcript before it
    /// could. Either way the request is over and the reporter comes back off the row.
    func noteScrollTargetResolved() {
        scrollTargetId = nil
    }

    // MARK: - Private

    private func apply(_ next: ScrollFlags) {
        let nextMode: Mode = next.following ? .following : .readingHistory
        if nextMode != mode { mode = nextMode }
        if next.showJumpButton != showJumpButton { showJumpButton = next.showJumpButton }
    }
}
