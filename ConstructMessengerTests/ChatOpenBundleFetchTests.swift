//
//  ChatOpenBundleFetchTests.swift
//  ConstructMessengerTests
//
//  Opening a chat spends none of the peer's one-time pre-keys (2026-10-13). A Mac linked with
//  history has no sessions, and every open of every chat fetched with `consume: true` into a
//  bundle nothing used.
//

import XCTest
@testable import Construct_Messenger

final class ChatOpenBundleFetchTests: XCTestCase {

    /// Mutation: `.fetch(consumeOneTimePrekey: !sessionExists)` — the code before this test —
    /// reddens the no-session cases.
    func testOpeningAChatNeverSpendsAOneTimePreKey() {
        for sessionExists in [false, true] {
            for identityKeyKnown in [false, true] {
                let decision = ChatSessionManager.bundleFetchOnOpen(
                    sessionExists: sessionExists, identityKeyKnown: identityKeyKnown
                )
                XCTAssertNotEqual(
                    decision, .fetch(consumeOneTimePrekey: true),
                    "session=\(sessionExists) key=\(identityKeyKnown)"
                )
            }
        }
    }

    /// A chat with no session still fetches: the identity key it brings is what stealth sealing
    /// needs, and the composer waits on it. Only a session with a known key skips the network.
    ///
    /// Mutation: return `.skip` whenever a session exists — the session-without-key case reddens.
    func testOnlyASessionWithAKnownKeySkipsTheFetch() {
        XCTAssertEqual(ChatSessionManager.bundleFetchOnOpen(sessionExists: true, identityKeyKnown: true), .skip)
        XCTAssertEqual(
            ChatSessionManager.bundleFetchOnOpen(sessionExists: true, identityKeyKnown: false),
            .fetch(consumeOneTimePrekey: false)
        )
        XCTAssertEqual(
            ChatSessionManager.bundleFetchOnOpen(sessionExists: false, identityKeyKnown: true),
            .fetch(consumeOneTimePrekey: false)
        )
        XCTAssertEqual(
            ChatSessionManager.bundleFetchOnOpen(sessionExists: false, identityKeyKnown: false),
            .fetch(consumeOneTimePrekey: false)
        )
    }
}
