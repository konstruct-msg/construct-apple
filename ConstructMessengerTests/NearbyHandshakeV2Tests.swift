//
//  NearbyHandshakeV2Tests.swift
//  ConstructMessengerTests
//
//  Hostile parse for CTT1 v2 (spec §6 / plan PR 5). Backup v1 stays on the
//  46-byte HandshakeFrame path.
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class NearbyHandshakeV2Tests: XCTestCase {

    private func failure(_ r: Result<Void, CTT1V2Error>) -> CTT1V2Error? {
        if case .failure(let e) = r { return e }
        return nil
    }

    private func isSuccess(_ r: Result<Void, CTT1V2Error>) -> Bool {
        if case .success = r { return true }
        return false
    }

    func testLayoutSumsMatchFrozenLengths() {
        XCTAssertEqual(CTT1V2Layout.prefixCount, 46)
        XCTAssertEqual(CTT1V2Layout.prefixCount, NearbyTransferService.HandshakeFrame.byteCount)
        XCTAssertEqual(CTT1V2Layout.openingCount, 6575)
        XCTAssertEqual(CTT1V2Layout.replyCount, 5421)
        XCTAssertEqual(CTT1V2Layout.hybridSigCount, 3373)
        XCTAssertEqual(CTT1V2Layout.kemCtCount, 1088)
        XCTAssertEqual(CTT1V2Layout.hybridPubCount, 1984)
    }

    func testV1PrefixStillParsesAsBackup() throws {
        var frame = Data("CTT1".utf8)
        frame.append(0x01)
        frame.append(Data(repeating: 0xAB, count: 32))
        frame.append(0x01)
        frame.append(contentsOf: UInt64(1234).littleEndianBytes)
        let prefix = try CTT1V2Prefix.parse(frame)
        XCTAssertEqual(prefix.version, 0x01)
        XCTAssertEqual(prefix.type, .backup)
        XCTAssertEqual(prefix.payloadLength, 1234)
        XCTAssertNoThrow(try NearbyTransferService.HandshakeFrame.parse(frame))
    }

    func testHistoryTypeOnV1IsRefused() throws {
        var frame = Data("CTT1".utf8)
        frame.append(0x01)
        frame.append(Data(repeating: 0xAB, count: 32))
        frame.append(0x02)
        frame.append(contentsOf: UInt64(0).littleEndianBytes)
        let prefix = try CTT1V2Prefix.parse(frame)
        XCTAssertEqual(failure(CTT1V2Verify.historyAccepts(prefix: prefix)), .v1RefusedForHistory)
    }

    func testSkipTypeOnV1IsRefused() throws {
        var frame = Data("CTT1".utf8)
        frame.append(0x01)
        frame.append(Data(repeating: 0xAB, count: 32))
        frame.append(0x03)
        frame.append(contentsOf: UInt64(0).littleEndianBytes)
        let prefix = try CTT1V2Prefix.parse(frame)
        XCTAssertEqual(failure(CTT1V2Verify.historyAccepts(prefix: prefix)), .v1RefusedForHistory)
    }

    func testShortOpeningIsMalformed() {
        XCTAssertThrowsError(try CTT1V2Opening.parse(Data(repeating: 0, count: 45)))
        XCTAssertThrowsError(try CTT1V2Opening.parse(Data(repeating: 0, count: 46)))
        XCTAssertThrowsError(try CTT1V2Opening.parse(Data(repeating: 0, count: 6574)))
    }

    func testWrongMagicIsMalformed() throws {
        var data = try openingVector()
        data[0] = 0x58
        XCTAssertThrowsError(try CTT1V2Opening.parse(data)) { err in
            XCTAssertEqual(err as? CTT1V2Error, .malformed)
        }
    }

    func testBackupTypeAtV2IsMalformed() throws {
        var data = try openingVector()
        data[37] = NearbyTransferService.TransferType.backup.rawValue
        XCTAssertThrowsError(try CTT1V2Opening.parse(data)) { err in
            XCTAssertEqual(err as? CTT1V2Error, .malformed)
        }
    }

    func testPayloadLenAbove2GiBIsMalformedOnPrefix() {
        var frame = Data("CTT1".utf8)
        frame.append(0x02)
        frame.append(Data(repeating: 0xAB, count: 32))
        frame.append(0x02)
        frame.append(contentsOf: UInt64.max.littleEndianBytes)
        XCTAssertThrowsError(try CTT1V2Prefix.parse(frame)) { err in
            XCTAssertEqual(err as? CTT1V2Error, .malformed)
        }
    }

    func testSenderDeviceIdMismatchIsIdentityMismatch() throws {
        let opening = try CTT1V2Opening.parse(try openingVector())
        var known = try knownOffering()
        known.localDeviceId = Data(repeating: 0x00, count: 16)
        XCTAssertEqual(failure(CTT1V2Verify.opening(opening, known: known)), .identityMismatch)
    }

    func testWrongKyberKeyIdIsKemMismatch() throws {
        let opening = try CTT1V2Opening.parse(try openingVector())
        var known = try knownOffering()
        known.kyberKeyId = 99
        XCTAssertEqual(failure(CTT1V2Verify.opening(opening, known: known)), .kemKeyIdMismatch)
    }

    func testAdvertisedKeyNotMatchingKnownIsIdentityMismatch() throws {
        let opening = try CTT1V2Opening.parse(try openingVector())
        var known = try knownOffering()
        known.identityPublic = Data(repeating: 0x11, count: 32)
        XCTAssertEqual(failure(CTT1V2Verify.opening(opening, known: known)), .identityMismatch)
    }

    func testMissingQrFpIsAbsent() throws {
        let opening = try CTT1V2Opening.parse(try openingVector())
        var known = try knownOffering()
        known.pin = .absent
        XCTAssertEqual(failure(CTT1V2Verify.opening(opening, known: known)), .qrPinAbsent)
    }

    func testWrongQrFpIsMismatch() throws {
        let opening = try CTT1V2Opening.parse(try openingVector())
        var known = try knownOffering()
        known.pin = .pinned(Data(repeating: 0xFF, count: 32))
        XCTAssertEqual(failure(CTT1V2Verify.opening(opening, known: known)), .qrPinMismatch)
    }

    func testEmptyHybridIsNoHybridKey() throws {
        let opening = try CTT1V2Opening.parse(try openingVector())
        var known = try knownOffering()
        known.hybridPublic = Data()
        XCTAssertEqual(failure(CTT1V2Verify.opening(opening, known: known)), .noHybridKey)
    }

    func testV20ReplyVerifiesWithV19Opening() throws {
        let opening = try CTT1V2Opening.parse(try openingVector())
        let reply = try CTT1V2Reply.parse(try replyVector())
        let keys = try vectorKeys()
        XCTAssertTrue(
            isSuccess(
                CTT1V2Verify.reply(
                    reply,
                    opening: opening,
                    knownIdentity: try hexData(keys.receiverIdentityPublic),
                    knownHybrid: try hexData(keys.hybridPublic)
                )
            )
        )
        let untagged = reply.taggedMessage(
            senderEphPub: opening.senderEphPub,
            snapshotId: opening.snapshotId,
            senderDeviceId: opening.senderDeviceId,
            receiverDeviceId: opening.receiverDeviceId,
            kemCt: opening.kemCt
        ).dropFirst(CTT1V2Layout.receiverTag.count)
        let ok = try hybridVerify(
            publicKey: [UInt8](reply.receiverHybridPub),
            message: [UInt8](untagged),
            signature: [UInt8](reply.signature)
        )
        XCTAssertFalse(ok, "reply signature must fail without the domain tag")
    }

    func testNonZeroOriginSliceParses() throws {
        let padded = Data(repeating: 0xFF, count: 11) + (try openingVector())
        let slice = padded[11...]
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertNoThrow(try CTT1V2Opening.parse(slice))
    }

    // MARK: - Vectors

    private struct VectorFile: Decodable {
        let keys: Keys
        let vectors: [Vector]
        enum CodingKeys: String, CodingKey {
            case keys = "$keys"
            case vectors
        }
    }

    private struct Keys: Decodable {
        let hybridPublic: String
        let offeringIdentityPublic: String
        let receiverIdentityPublic: String
        let receiverDeviceIdRaw: String
        enum CodingKeys: String, CodingKey {
            case hybridPublic = "hybrid_public"
            case offeringIdentityPublic = "offering_identity_public"
            case receiverIdentityPublic = "receiver_identity_public"
            case receiverDeviceIdRaw = "receiver_device_id_raw"
        }
    }

    private struct Vector: Decodable {
        let id: String
        let hex: String?
    }

    private func loadFile() throws -> VectorFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_history_snapshot.json")
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private func vector(id: String) throws -> Data {
        let file = try loadFile()
        let hex = try XCTUnwrap(file.vectors.first(where: { $0.id == id })?.hex)
        return try hexData(hex)
    }

    private func openingVector() throws -> Data { try vector(id: "V19") }
    private func replyVector() throws -> Data { try vector(id: "V20") }

    private func vectorKeys() throws -> Keys { try loadFile().keys }

    private func knownOffering() throws -> CTT1V2Verify.Known {
        let keys = try vectorKeys()
        let identity = try hexData(keys.offeringIdentityPublic)
        let hybrid = try hexData(keys.hybridPublic)
        return CTT1V2Verify.Known(
            identityPublic: identity,
            hybridPublic: hybrid,
            localDeviceId: try hexData(keys.receiverDeviceIdRaw),
            kyberKeyId: 7,
            pin: .pinned(HistorySnapshotDisposition.qrFingerprint(identityPublic: identity, hybridPublic: hybrid))
        )
    }

    private func hexData(_ hex: String) throws -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { throw CTT1V2Error.malformed }
            out.append(b)
            i = j
        }
        return out
    }
}

private extension UInt64 {
    var littleEndianBytes: [UInt8] {
        var le = littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }
}
