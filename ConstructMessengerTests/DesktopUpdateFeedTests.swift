//
//  DesktopUpdateFeedTests.swift
//  ConstructMessengerTests
//
//  Desktop ships one thin DMG per architecture, so each build must read its own feed: an Intel
//  Mac offered the arm64 DMG installs an app that does not launch.
//

import XCTest
@testable import Construct_Messenger

final class DesktopUpdateFeedTests: XCTestCase {

    /// Mutation: one feed for both — the arm64 URL for x86_64.
    func testEachArchitectureHasItsOwnFeed() {
        XCTAssertEqual(DesktopUpdateFeed.url(for: .arm64).lastPathComponent, "appcast-arm64.xml")
        XCTAssertEqual(DesktopUpdateFeed.url(for: .x86_64).lastPathComponent, "appcast-x86_64.xml")
        XCTAssertEqual(DesktopUpdateFeed.url(for: .arm64).deletingLastPathComponent(),
                       DesktopUpdateFeed.url(for: .x86_64).deletingLastPathComponent())
    }

    /// The feed is an asset of the fixed release `build_desktop_dmg.sh --publish` writes to.
    func testTheFeedIsTheFixedRelease() {
        XCTAssertEqual(DesktopUpdateFeed.url(for: .arm64).absoluteString,
                       "https://github.com/konstruct-msg/construct-apple/releases/download/desktop-beta-feed/appcast-arm64.xml")
    }

    /// Only an explicit YES turns updates on; an unexpanded build setting does not.
    /// Mutation: `!= "NO"` — the unexpanded and missing cases turn updates on.
    func testUpdatesAreOnOnlyWhenTheBuildSaysYes() {
        XCTAssertTrue(DesktopUpdateFeed.isEnabled(infoValue: "YES"))
        XCTAssertFalse(DesktopUpdateFeed.isEnabled(infoValue: "NO"))
        XCTAssertFalse(DesktopUpdateFeed.isEnabled(infoValue: "$(DESKTOP_UPDATES_ENABLED)"))
        XCTAssertFalse(DesktopUpdateFeed.isEnabled(infoValue: nil))
    }
}
