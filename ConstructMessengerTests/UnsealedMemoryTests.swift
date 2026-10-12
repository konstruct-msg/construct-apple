//
//  UnsealedMemoryTests.swift
//  ConstructMessengerTests
//
//  Leaving the screen drops the store key and the decrypted text the app keeps for speed
//  (UnsealedMemory), and the text is zeroed rather than merely freed.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class UnsealedMemoryTests: XCTestCase {

    override func tearDown() {
        MessageDisplayCache.shared.evict(messageId: "unsealed-memory-test")
        super.tearDown()
    }

    private func holdBoth() throws {
        _ = try XCTUnwrap(LocalStoreKey.current(), "the test host's Keychain must answer")
        MessageDisplayCache.shared.store(messageId: "unsealed-memory-test", plaintext: "the text")
        XCTAssertTrue(LocalStoreKey.isCached)
        XCTAssertNotNil(MessageDisplayCache.shared.cachedPayload(messageId: "unsealed-memory-test"))
    }

    /// The wiring, not only the function: the system's background notification is what drops them.
    ///
    /// Mutation: remove the observer in `forgetOnBackground` — this reddens.
    func testLeavingTheScreenDropsTheKeyAndTheText() throws {
        UnsealedMemory.forgetOnBackground()
        try holdBoth()

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        XCTAssertFalse(LocalStoreKey.isCached, "the store key is read from the Keychain again on return")
        XCTAssertNil(MessageDisplayCache.shared.cachedPayload(messageId: "unsealed-memory-test"))
    }

    /// Each half on its own.
    ///
    /// Mutations: drop either line of `forget` — this reddens.
    func testForgetDropsBoth() throws {
        try holdBoth()
        UnsealedMemory.forget(reason: "test")
        XCTAssertFalse(LocalStoreKey.isCached)
        XCTAssertNil(MessageDisplayCache.shared.cachedPayload(messageId: "unsealed-memory-test"))
    }

    /// The bytes are zeroed in place, not merely released.
    ///
    /// Mutation: make `wipe` a no-op — this reddens.
    func testTheCachedTextIsZeroedNotFreed() {
        var data = Data("the text".utf8)
        WipedOnRelease.wipe(&data)
        XCTAssertEqual(data.count, 8)
        XCTAssertTrue(data.allSatisfy { $0 == 0 })
    }
}
