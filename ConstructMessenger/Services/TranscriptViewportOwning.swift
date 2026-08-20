//
//  TranscriptViewportOwning.swift
//  Construct Messenger
//
//  The surface `ChatView` and `DesktopChatView` need from whoever owns the transcript's scroll
//  position, so one body can run against either owner while the flag exists.
//
//  **This protocol is scaffolding and dies with the flag in PR-4.** It is not an abstraction over
//  scrolling — it is the exact set of calls the two hosts already make, renamed once so the two
//  owners can answer them. Do not add a member to make something convenient; add it only because a
//  host cannot be written without it, and delete the whole file when `ChatScrollManager` goes.
//
//  The alternative was branching at each of the fourteen call sites, which the decision rejects in
//  as many words ("не 200 строк `if` в `body`"), and the alternative after that was two host views
//  duplicating four hundred lines of nav, search and gallery for the length of a soak.
//

import SwiftUI
import Observation

@MainActor
protocol TranscriptViewportOwning: AnyObject, Observable {

    // MARK: - What the view renders from

    /// The newest message must stay visible.
    var isFollowing: Bool { get }

    /// The "jump to newest" control is warranted.
    var showJumpButton: Bool { get }

    /// The transcript has settled enough that geometry describes a reader rather than a layout in
    /// flight. The old owner answers this from its opening timer, the new one from the tail
    /// actually being on screen.
    var layoutPrimed: Bool { get }

    /// The row the reader is held to, or nil while following.
    ///
    /// Only the owned-inset path binds this to `.scrollPosition(id:)`; the legacy owner has no
    /// such concept and keeps it nil. Measured limit (PR-0): the binding holds a row against a
    /// growing inset, and does not survive content inserted above it.
    var heldMessageId: String? { get set }

    /// One line for the geometry probe. Kept as a string so the log does not have to know which
    /// owner produced it.
    var stateDescription: String { get }

    // MARK: - What the view reports

    func registerProxy(_ proxy: ScrollViewProxy)

    /// The transcript container appeared with this many messages already loaded.
    func noteTranscriptAppeared(messageCount: Int)

    func updateGeometry(_ geometry: ChatScrollGeometry, messageCount: Int)

    func noteScrollPhase(_ phase: ScrollPhase)

    /// The newest row entered or left the viewport.
    func noteLastMessageVisible(_ visible: Bool, searchActive: Bool)

    /// The bottom of the viewport changed shape. All three sources arrive together because they
    /// latch the same thing — a keyboard moves the safe area and the container without touching
    /// the composer's own height.
    func noteComposerGeometry(composerHeight: CGFloat, safeAreaBottom: CGFloat, containerHeight: CGFloat)

    func handleTranscriptCountChange(oldCount: Int, newCount: Int, searchActive: Bool)

    func shouldLoadOlderHistory(isSearchActive: Bool, isLoadingMore: Bool, hasMoreMessages: Bool) -> Bool

    // MARK: - What the view asks for

    /// Back to the newest message, by explicit request only: the jump control, and dismissing
    /// search. Everything else that used to call this is now the scroll anchor's job.
    func followExplicitly()

    /// Guest scrolls — a search hit, a reply parent, the voice message now playing. They never
    /// decide who owns the viewport.
    func scrollTo(messageId: String, anchor: UnitPoint, animated: Bool)
}
