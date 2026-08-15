//
//  InviteShareDecisionTests.swift
//  ConstructMessengerTests
//
//  Created 2026-08-15.
//

import XCTest
@testable import Construct_Messenger

/// The invite sheet's copy button, as decisions rather than as a view.
///
/// Named after what went wrong: a single `linkCopied: Bool` made every tap after the
/// first render identically, so the rule "each tap mints a new one-time link" was
/// invisible at the exact moment it fired. A whole screen (`MultiInviteView`, five
/// pre-minted capabilities on open) was built to work around that, and deleted with it.
final class InviteShareDecisionTests: XCTestCase {

    // MARK: - Copy feedback

    func testNothingCopiedYetShowsRestingLabel() {
        XCTAssertEqual(InviteShareDecision.feedback(copiedCount: 0), .idle)
    }

    /// The regression this file exists for. If these two ever compare equal, the second
    /// tap is again indistinguishable from the first and the minting rule goes unsaid.
    func testSecondCopyMustNotReadLikeTheFirst() {
        let first  = InviteShareDecision.feedback(copiedCount: 1)
        let second = InviteShareDecision.feedback(copiedCount: 2)
        XCTAssertEqual(first, .copied)
        XCTAssertEqual(second, .copiedAgain(2))
        XCTAssertNotEqual(first, second)
    }

    /// The count must reach the label, not just the branch — otherwise taps three and
    /// four collapse into one another the way one and two used to.
    func testEveryFurtherCopyCarriesItsOwnNumber() {
        XCTAssertEqual(InviteShareDecision.feedback(copiedCount: 3), .copiedAgain(3))
        XCTAssertEqual(InviteShareDecision.feedback(copiedCount: 7), .copiedAgain(7))
        XCTAssertNotEqual(
            InviteShareDecision.feedback(copiedCount: 3),
            InviteShareDecision.feedback(copiedCount: 4)
        )
    }

    /// A count can only be raised by a successful mint, so a negative or absurd value is
    /// a programming error upstream. Pinned so it degrades to "resting", never to a
    /// label claiming a link is on the clipboard.
    func testNegativeCountIsTreatedAsNothingCopied() {
        XCTAssertEqual(InviteShareDecision.feedback(copiedCount: -1), .idle)
    }

    // MARK: - Debounce

    func testFirstTapAlwaysMints() {
        XCTAssertTrue(
            InviteShareDecision.shouldMint(now: Date(), lastMintAt: nil, debounce: 0.3)
        )
    }

    /// Finger dribble is rejected; a deliberate second tap is not. The upper case is the
    /// one that matters — the user tapping again wants a link for the next person, and
    /// swallowing it while the button still reads "copied" hands them the previous link
    /// twice without saying so.
    func testDebounceRejectsDribbleButNotADeliberateSecondTap() {
        let mintedAt = Date()
        XCTAssertFalse(
            InviteShareDecision.shouldMint(
                now: mintedAt.addingTimeInterval(0.1), lastMintAt: mintedAt, debounce: 0.3
            ),
            "0.1 s after a mint is one tap registering twice"
        )
        XCTAssertTrue(
            InviteShareDecision.shouldMint(
                now: mintedAt.addingTimeInterval(0.4), lastMintAt: mintedAt, debounce: 0.3
            ),
            "0.4 s after a mint is a person asking for another link"
        )
    }

    // There is deliberately no test pinning the exact boundary. `Date` arithmetic at
    // 0.3 s lands on 0.29999999999999993, so such a test asserts a rounding artifact
    // rather than the decision — and no tap arrives at a instant the window can resolve.
    // The two cases above are the claim worth making.

    /// The shipped window. A multi-second value here is not a stricter version of the
    /// same guard — it changes what the button does, from "debounced" to "rate limited",
    /// and the sheet's copy promises the former.
    func testShippedDebounceStaysBelowAHumanSecondTap() {
        XCTAssertLessThanOrEqual(SettingsShareLayout.copyDebounce, 0.5)
    }
}
