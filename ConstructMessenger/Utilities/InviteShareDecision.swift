//
//  InviteShareDecision.swift
//  Construct Messenger
//
//  Created 2026-08-15.
//

import Foundation

/// The two decisions behind the invite sheet's copy button, as pure functions.
///
/// Both used to live inside a view — one as an early `return` in a `@MainActor` method,
/// the other as a ternary on a `Bool`. Neither could be reached by a test, and the second
/// was wrong: a single `linkCopied` flag renders the second tap exactly like the first,
/// so the tap that minted a fresh link for the next person looked like nothing happened.
/// That is the whole reason `MultiInviteView` existed — a screen built to make visible a
/// rule the button was hiding.
enum InviteShareDecision {

    /// What the copy button says after `copiedCount` links have been minted this session.
    ///
    /// The distinction between `.copied` and `.copiedAgain` is the point: the button is the
    /// only place that tells the user tapping again produced a *different* link.
    enum CopyFeedback: Equatable {
        /// Nothing copied yet — the button shows its resting label.
        case idle
        /// First link of this session.
        case copied
        /// Nth link, N ≥ 2. Carries N so the label can show it.
        case copiedAgain(Int)
    }

    static func feedback(copiedCount: Int) -> CopyFeedback {
        guard copiedCount > 0 else { return .idle }
        guard copiedCount > 1 else { return .copied }
        return .copiedAgain(copiedCount)
    }

    /// Whether a tap should mint. Guards finger dribble only.
    ///
    /// A long debounce here is not a safety feature, it is the defect: every tap is meant
    /// to create a new one-time invite, so a window wide enough to swallow a deliberate
    /// second tap silently denies the user the link they asked for — while the button,
    /// under `.copied`, claims one is on the clipboard.
    static func shouldMint(now: Date, lastMintAt: Date?, debounce: TimeInterval) -> Bool {
        guard let lastMintAt else { return true }
        return now.timeIntervalSince(lastMintAt) >= debounce
    }
}
