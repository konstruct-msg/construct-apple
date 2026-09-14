//
//  EmojiCatalogueTests.swift
//  ConstructMessengerTests
//
//  The picker's contents, and the one property that makes it a picker rather than a keyboard:
//  everything it offers is something the wire will accept.
//
//  What it replaces is why that matters. "More reactions" was a `UITextField` overriding
//  `textInputMode` to ask for the emoji keyboard — a preference iOS may ignore, and on device it
//  did: the screen showed the letter keyboard over an empty box. The field forwarded every
//  keystroke, and `isValidEmoji` accepted anything short, so a letter went out as a reaction and
//  arrived on the far side (device log 2026-08-21 14:39:42, `set(emoji: "H")`).
//
//  Acceptance is mutation-based; each test names the mutation that must redden it.
//

import XCTest
@testable import Construct_Messenger

final class EmojiCatalogueTests: XCTestCase {

    /// The invariant that ties the two halves together. A catalogue entry the validator refuses is
    /// a dead key — you tap it, nothing happens, and nothing says why. This is the same predicate
    /// the receiving peer applies.
    ///
    /// Mutation: drop the `isValidEmoji` filter in the builder.
    func testEveryOfferedEmojiIsOneTheWireAccepts() {
        for group in EmojiCatalogue.groups {
            for emoji in group.emoji {
                XCTAssertTrue(
                    ReactionReducer.isValidEmoji(emoji),
                    "\(emoji) is offered in \(group.id) but would be refused as a reaction"
                )
            }
        }
    }

    /// ❤ is U+2764: emoji by property, *text* by default presentation, and drawn as a heart only
    /// with U+FE0F after it. It is also the first entry of the quick set and the double-tap target,
    /// so a picker without it would be missing the one emoji the app uses most.
    ///
    /// Mutation: drop the `isEmojiPresentation` branch and offer the bare scalar. The filter above
    /// then removes it and this fails.
    func testTheHeartIsOfferedInItsPresentationForm() {
        let all = EmojiCatalogue.groups.flatMap(\.emoji)
        XCTAssertTrue(all.contains("❤️"), "the quick set's own heart must be in the full picker")
        XCTAssertFalse(all.contains("❤"), "the bare text-presentation scalar is not what gets sent")
    }

    /// A picker with three emoji in it would pass every test above. This is the one that says it is
    /// actually a catalogue — and it is deliberately a floor, not an exact count: the ranges are
    /// filtered through what *this* OS can draw, so the number rises with a new iOS and must not
    /// need an edit here when it does.
    ///
    /// Mutation: return only the first range of each group.
    func testTheCatalogueIsNotAToken() {
        let total = EmojiCatalogue.groups.reduce(0) { $0 + $1.emoji.count }
        XCTAssertGreaterThan(total, 500, "every published block, filtered — not a handful")
        XCTAssertEqual(EmojiCatalogue.groups.count, 8)
    }

    /// Empty sections would render as a heading with nothing under it — the same "there is nothing
    /// here" the screen was reported for.
    ///
    /// Mutation: return `Group(...)` unconditionally instead of `nil` for an empty one.
    func testNoGroupIsEmpty() {
        for group in EmojiCatalogue.groups {
            XCTAssertFalse(group.emoji.isEmpty, "\(group.id) would draw a heading over nothing")
        }
    }

    /// Duplicates across groups would show the same emoji twice with no way to tell why.
    func testNoEmojiIsOfferedTwice() {
        let all = EmojiCatalogue.groups.flatMap(\.emoji)
        XCTAssertEqual(all.count, Set(all).count)
    }

    /// Every heading resolves. A missing key is displayed to the user verbatim as
    /// `emoji_group_travel`, which is how the twelve in `check_localization.sh`'s BASELINE got
    /// onto real screens.
    func testEveryGroupHeadingIsLocalised() {
        for group in EmojiCatalogue.groups {
            XCTAssertNotEqual(
                NSLocalizedString(group.id, comment: ""), group.id,
                "\(group.id) has no entry and would be shown to the user as its own key"
            )
        }
    }

    /// Filtering is by section heading, which is what can be done without an emoji name table.
    /// An empty query is not a filter.
    func testAnEmptyQueryIsNotAFilter() {
        XCTAssertEqual(EmojiCatalogue.groups(matching: "   ").count, EmojiCatalogue.groups.count)
    }
}
