//
//  TransferCryptoTests.swift
//  ConstructMessengerTests
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class TransferCryptoTests: XCTestCase {

    func testChunkWithWrongIndexDoesNotOpen() throws {
        let snapshot = Data(repeating: 0xAA, count: 16)
        let user = Data(repeating: 0x01, count: 16)
        let key = TransferCrypto.deriveChannelKey(
            ecdh: Data(repeating: 0x11, count: 32),
            kemSharedSecret: Data(repeating: 0x22, count: 32),
            salt: .nearby,
            snapshotId: snapshot
        )
        let nonce = try ChaChaPoly.Nonce(data: Data(count: 12))
        let aad0 = TransferCrypto.chunkAAD(snapshotId: snapshot, userId: user, index: 0)
        let aad1 = TransferCrypto.chunkAAD(snapshotId: snapshot, userId: user, index: 1)
        XCTAssertNotEqual(aad0, aad1)

        let sealed = try ChaChaPoly.seal(Data("chunk".utf8), using: key, nonce: nonce, authenticating: aad0)
        XCTAssertEqual(
            try ChaChaPoly.open(sealed, using: key, authenticating: aad0),
            Data("chunk".utf8)
        )
        XCTAssertThrowsError(try ChaChaPoly.open(sealed, using: key, authenticating: aad1))
    }

    func testNearbyAndFileSaltsDiverge() {
        let ecdh = Data(repeating: 0x33, count: 32)
        let kem = Data(repeating: 0x44, count: 32)
        let snap = Data(repeating: 0x55, count: 16)
        let nearby = TransferCrypto.deriveChannelKey(ecdh: ecdh, kemSharedSecret: kem, salt: .nearby, snapshotId: snap)
        let file = TransferCrypto.deriveChannelKey(ecdh: ecdh, kemSharedSecret: kem, salt: .file, snapshotId: snap)
        XCTAssertNotEqual(nearby.withUnsafeBytes { Data($0) }, file.withUnsafeBytes { Data($0) })
    }

    func testDiscoveryInstanceNameMatchesDisposition() {
        let tag = HistorySnapshotDisposition.discoveryTag(
            userIdDashed: "00000000-0000-4000-8000-000000000001",
            newDeviceIdHex: "65cf5c9b1de5d41f758cb67f2d05f3e3"
        )
        XCTAssertEqual(
            TransferCrypto.discoveryInstanceName(tag: tag),
            HistorySnapshotDisposition.discoveryInstanceName(tag: tag)
        )
    }
}
