//
//  ChatTextPreferenceTests.swift
//  ConstructMessengerTests
//
//  Message text is the one font in the app the reader chooses, and the scope is the point:
//  bubbles and the composer that fills them, nothing else. Monospace is the language of the
//  chrome; what a person writes and reads is content.
//
//  The size half of this was already in the Appearance screen and had never been connected —
//  `@AppStorage("textSize")` had no reader anywhere in the app and the bubble used a hard-coded
//  15. Shipping a second reading-comfort control beside a dead one would have been the wrong half
//  of an apology, so both are wired through the same token.
//

import XCTest
import SwiftUI
@testable import Construct_Messenger

final class ChatTextPreferenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ChatTextPreference.faceKey)
        UserDefaults.standard.removeObject(forKey: ChatTextPreference.sizeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ChatTextPreference.faceKey)
        UserDefaults.standard.removeObject(forKey: ChatTextPreference.sizeKey)
        super.tearDown()
    }

    // MARK: - Face

    /// The terminal face is what the product looks like. An unset preference must not quietly
    /// change that for everyone who never opens Appearance.
    func testTheDefaultFaceIsMono() {
        XCTAssertEqual(ChatTextPreference.face, .mono)
    }

    func testTheStoredFaceIsHonoured() {
        UserDefaults.standard.set("system", forKey: ChatTextPreference.faceKey)
        XCTAssertEqual(ChatTextPreference.face, .system)
        UserDefaults.standard.set("mono", forKey: ChatTextPreference.faceKey)
        XCTAssertEqual(ChatTextPreference.face, .mono)
    }

    /// A value nobody wrote — a downgrade, a corrupted domain, a future build's option — falls to
    /// the default rather than to whatever `Face(rawValue:)` does with it.
    func testAnUnknownStoredFaceFallsBackToMono() {
        UserDefaults.standard.set("comic", forKey: ChatTextPreference.faceKey)
        XCTAssertEqual(ChatTextPreference.face, .mono)
    }

    // MARK: - Size

    /// **The setting that did nothing.** Each of the three values in the Appearance screen must
    /// now move the multiplier, and `standard` must be exactly 1 so the default rendering is
    /// unchanged for everyone who never touched it.
    func testEveryOfferedSizeChangesSomething() {
        UserDefaults.standard.set("standard", forKey: ChatTextPreference.sizeKey)
        XCTAssertEqual(ChatTextPreference.sizeMultiplier, 1.0)

        UserDefaults.standard.set("compact", forKey: ChatTextPreference.sizeKey)
        let compact = ChatTextPreference.sizeMultiplier
        UserDefaults.standard.set("large", forKey: ChatTextPreference.sizeKey)
        let large = ChatTextPreference.sizeMultiplier

        XCTAssertLessThan(compact, 1.0, "compact must actually be smaller")
        XCTAssertGreaterThan(large, 1.0, "large must actually be larger")
        XCTAssertNotEqual(compact, large)
    }

    /// Unset reads as standard: an install that predates the wiring must render exactly as before.
    func testAnUnsetSizeIsStandard() {
        XCTAssertEqual(ChatTextPreference.sizeMultiplier, 1.0)
    }

    /// Every case the settings screen offers is a case the multiplier knows. A fourth option added
    /// to `TextSize` without a branch here would silently render at standard.
    func testTheSettingsScreenOffersNothingTheMultiplierIgnores() {
        var seen: Set<CGFloat> = []
        for size in TextSize.allCases {
            UserDefaults.standard.set(size.rawValue, forKey: ChatTextPreference.sizeKey)
            seen.insert(ChatTextPreference.sizeMultiplier)
        }
        XCTAssertEqual(
            seen.count, TextSize.allCases.count,
            "each offered size must map to a distinct multiplier — a shared one is an option that does nothing"
        )
    }

    // MARK: - Scope

    /// The chrome is not the reader's to change. `regular` sets nav bars, `> TITLE` headers,
    /// badges and separators; if the preference reached it, choosing a comfortable message font
    /// would turn the product into a different product.
    func testTheChromeIgnoresThePreference() {
        UserDefaults.standard.set("system", forKey: ChatTextPreference.faceKey)
        XCTAssertEqual(
            CTFont.regular(15), ConstructFont.mono(15, weight: .regular),
            "CTFont.regular must stay monospaced whatever the message preference says"
        )
    }

    /// And the message font does move with it — otherwise the test above passes for the wrong
    /// reason, which is the shape of a suite that proves nothing.
    func testTheMessageFontFollowsThePreference() {
        UserDefaults.standard.set("mono", forKey: ChatTextPreference.faceKey)
        let mono = CTFont.message(15)
        UserDefaults.standard.set("system", forKey: ChatTextPreference.faceKey)
        XCTAssertNotEqual(mono, CTFont.message(15))
    }
}
