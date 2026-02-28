//
//  SessionStoreTests.swift
//  ConstructMessengerTests
//
//  Tests for SessionStore — in-memory session registry mapping user IDs to session IDs.
//

import XCTest
@testable import ConstructMessenger

final class SessionStoreTests: XCTestCase {

    private var store: SessionStore!

    override func setUp() {
        super.setUp()
        store = SessionStore()
    }

    // MARK: - hasSession

    func testHasSessionReturnsFalseWhenEmpty() {
        XCTAssertFalse(store.hasSession(for: "alice"))
    }

    func testHasSessionReturnsTrueAfterSet() {
        store.setSession(userId: "alice", sessionId: "sess-1", suiteId: 1)
        XCTAssertTrue(store.hasSession(for: "alice"))
    }

    func testHasSessionReturnsFalseForDifferentUser() {
        store.setSession(userId: "alice", sessionId: "sess-1", suiteId: 1)
        XCTAssertFalse(store.hasSession(for: "bob"))
    }

    // MARK: - getSessionId

    func testGetSessionIdReturnsNilWhenEmpty() {
        XCTAssertNil(store.getSessionId(for: "alice"))
    }

    func testGetSessionIdReturnsSetValue() {
        store.setSession(userId: "alice", sessionId: "sess-abc", suiteId: 1)
        XCTAssertEqual(store.getSessionId(for: "alice"), "sess-abc")
    }

    func testGetSessionIdReturnsNilForDifferentUser() {
        store.setSession(userId: "alice", sessionId: "sess-1", suiteId: 1)
        XCTAssertNil(store.getSessionId(for: "charlie"))
    }

    // MARK: - getSuiteId

    func testGetSuiteIdReturnsNilWhenEmpty() {
        XCTAssertNil(store.getSuiteId(for: "alice"))
    }

    func testGetSuiteIdReturnsSetValue() {
        store.setSession(userId: "alice", sessionId: "sess-1", suiteId: 2)
        XCTAssertEqual(store.getSuiteId(for: "alice"), 2)
    }

    func testGetSuiteIdReturnsCorrectValuePerUser() {
        store.setSession(userId: "alice", sessionId: "sess-1", suiteId: 1)
        store.setSession(userId: "bob", sessionId: "sess-2", suiteId: 2)
        XCTAssertEqual(store.getSuiteId(for: "alice"), 1)
        XCTAssertEqual(store.getSuiteId(for: "bob"), 2)
    }

    // MARK: - setSession (overwrite)

    func testSetSessionOverwritesPreviousSession() {
        store.setSession(userId: "alice", sessionId: "sess-old", suiteId: 1)
        store.setSession(userId: "alice", sessionId: "sess-new", suiteId: 2)
        XCTAssertEqual(store.getSessionId(for: "alice"), "sess-new")
        XCTAssertEqual(store.getSuiteId(for: "alice"), 2)
    }

    // MARK: - removeSession

    func testRemoveSessionClearsEntry() {
        store.setSession(userId: "alice", sessionId: "sess-1", suiteId: 1)
        store.removeSession(for: "alice")
        XCTAssertFalse(store.hasSession(for: "alice"))
        XCTAssertNil(store.getSessionId(for: "alice"))
        XCTAssertNil(store.getSuiteId(for: "alice"))
    }

    func testRemoveSessionDoesNotAffectOtherUsers() {
        store.setSession(userId: "alice", sessionId: "sess-1", suiteId: 1)
        store.setSession(userId: "bob", sessionId: "sess-2", suiteId: 1)
        store.removeSession(for: "alice")
        XCTAssertTrue(store.hasSession(for: "bob"))
        XCTAssertEqual(store.getSessionId(for: "bob"), "sess-2")
    }

    func testRemoveNonExistentSessionIsNoOp() {
        // Should not crash
        store.removeSession(for: "nobody")
        XCTAssertFalse(store.hasSession(for: "nobody"))
    }

    // MARK: - allUserIds

    func testAllUserIdsEmptyWhenNoSessions() {
        XCTAssertTrue(store.allUserIds().isEmpty)
    }

    func testAllUserIdsContainsSetUsers() {
        store.setSession(userId: "alice", sessionId: "s1", suiteId: 1)
        store.setSession(userId: "bob", sessionId: "s2", suiteId: 1)
        let ids = Set(store.allUserIds())
        XCTAssertEqual(ids, Set(["alice", "bob"]))
    }

    func testAllUserIdsDoesNotContainRemovedUser() {
        store.setSession(userId: "alice", sessionId: "s1", suiteId: 1)
        store.setSession(userId: "bob", sessionId: "s2", suiteId: 1)
        store.removeSession(for: "alice")
        XCTAssertFalse(store.allUserIds().contains("alice"))
        XCTAssertTrue(store.allUserIds().contains("bob"))
    }

    // MARK: - Multiple users

    func testMultipleUsersIndependent() {
        let users = ["alice", "bob", "charlie", "dave"]
        for (i, user) in users.enumerated() {
            store.setSession(userId: user, sessionId: "sess-\(i)", suiteId: UInt16(i))
        }
        for (i, user) in users.enumerated() {
            XCTAssertTrue(store.hasSession(for: user))
            XCTAssertEqual(store.getSessionId(for: user), "sess-\(i)")
            XCTAssertEqual(store.getSuiteId(for: user), UInt16(i))
        }
    }
}
