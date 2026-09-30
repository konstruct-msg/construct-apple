//
//  AtRestSealTests.swift
//  ConstructMessengerTests
//
//  What this device keeps at rest is sealed under `LocalStoreKey`, and the per-message keys are
//  no longer stored in the clear. `decisions/macos-store-encrypted-at-rest.md` (variant B)
//

import CryptoKit
import SQLite3
import XCTest
@testable import Construct_Messenger

final class AtRestSealTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)

    func testASealedValueOpensOnlyUnderItsKeyAndItsRow() throws {
        let sealed = try AtRestSeal.seal(Data("storage key".utf8), under: key, boundTo: "m1")

        XCTAssertEqual(try AtRestSeal.open(sealed, under: key, boundTo: "m1"), Data("storage key".utf8))
        XCTAssertThrowsError(try AtRestSeal.open(sealed, under: key, boundTo: "m2"),
                             "moved to another row, it does not open")
        XCTAssertThrowsError(try AtRestSeal.open(sealed, under: SymmetricKey(size: .bits256), boundTo: "m1"))
    }

    func testASealedKeyIsNeverThirtyTwoBytes() throws {
        // `MessageKeyStore` reads a 32-byte blob as a clear key from before sealing; a sealed one
        // must never be mistaken for it.
        let sealed = try AtRestSeal.seal(Data(repeating: 7, count: 32), under: key, boundTo: "m1")
        XCTAssertEqual(sealed.count, 32 + AtRestSeal.overhead)
    }

    // MARK: - The key store

    /// Mutation: store the key as given — the blob on disk is the key and this reddens.
    func testTheKeyStoreDoesNotKeepTheClearKey() throws {
        let messageId = "at-rest-\(UUID().uuidString)"
        let clear = Data((0..<32).map { UInt8($0) })
        MessageKeyStore.shared.storeSync(messageId: messageId, key: clear, contactId: "c")
        defer { MessageKeyStore.shared.delete(messageId: messageId) }

        let stored = try XCTUnwrap(MessageKeyStore.shared.storedBlobForTesting(messageId: messageId))
        XCTAssertNotEqual(stored, clear)
        XCTAssertNil(stored.range(of: clear), "the clear key is nowhere in the stored blob")
        XCTAssertEqual(MessageKeyStore.shared.fetch(messageId: messageId), clear)
    }

    /// A backup carries the keys in the clear inside its own encryption, so another device can
    /// open it. Mutation: export the file as stored — the copy holds sealed blobs and this reddens.
    func testThePortableCopyHoldsTheClearKey() throws {
        let messageId = "portable-\(UUID().uuidString)"
        let clear = Data((100..<132).map { UInt8($0) })
        MessageKeyStore.shared.storeSync(messageId: messageId, key: clear, contactId: "c")
        defer { MessageKeyStore.shared.delete(messageId: messageId) }

        let copy = try XCTUnwrap(MessageKeyStore.shared.portableCopy())
        XCTAssertNotNil(copy.range(of: clear))
    }
}
