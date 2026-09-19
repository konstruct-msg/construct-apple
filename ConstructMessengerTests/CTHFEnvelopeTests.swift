//
//  CTHFEnvelopeTests.swift
//  ConstructMessengerTests
//

import CoreData
import CryptoKit
import XCTest
@testable import Construct_Messenger

final class CTHFEnvelopeTests: XCTestCase {

    func testWrongRecipientFails() throws {
        let header = try CTHFHeader.parse(try v23())
        var known = try knownOffering()
        known.recipientDeviceId = Data(repeating: 0xFF, count: 16)
        if case .failure(let err) = CTHFVerify.header(header, known: known) {
            XCTAssertEqual(err, .identityMismatch)
        } else {
            XCTFail("wrong recipient must fail")
        }
    }

    func testTamperedChunkFailsAndLeavesFile() throws {
        let url = try writeFixtureFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var data = try Data(contentsOf: url)
        let idx = CTT1V2Layout.cthfHeaderCount + 8
        data[idx] ^= 0xFF
        try data.write(to: url)
        let header = try CTHFHeader.parse(try v23())
        let key = try vectorKey()
        XCTAssertThrowsError(try CTHFEnvelope.readRecords(from: url, header: header, key: key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTruncatedFileFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cth-trunc-\(UUID().uuidString).cthf")
        try (try v23()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let header = try CTHFHeader.parse(try v23())
        XCTAssertThrowsError(try CTHFEnvelope.readRecords(from: url, header: header, key: try vectorKey()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testSuccessfulImportDeletesFile() throws {
        let url = try writeFixtureFile()
        let header = try CTHFHeader.parse(try v23())
        let user = try XCTUnwrap(HistoryAccountID.dashed(header.userId))
        let store = PersistenceController(inMemory: true).container
        let summary = try CTHFEnvelope.importFile(
            at: url,
            expected: try knownOffering(),
            key: try vectorKey(),
            expectedUserId: user,
            in: store.viewContext
        )
        XCTAssertGreaterThan(summary.applied, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFinishLinkSourceAlwaysCheckpoints() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/ViewModels/DeviceLinkViewModel.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("applyAccountOnlyCheckpoint"))
        XCTAssertFalse(
            src.contains("!DeviceLinkHistorySyncPolicy.isPostLinkEnabled"),
            "cursor must not be gated on the history offer flag"
        )
    }

    func testCheckpointValueIndependentOfHistoryFlag() {
        XCTAssertEqual(
            DeviceLinkStreamCursorPolicy.checkpointCursor(issuedAtSeconds: 1_700_000_000),
            "1700000000000-0"
        )
        XCTAssertFalse(DeviceLinkHistorySyncPolicy.isPostLinkEnabled)
        XCTAssertEqual(
            DeviceLinkStreamCursorPolicy.checkpointCursor(issuedAtSeconds: 1_700_000_000),
            "1700000000000-0",
            "cursor formula must not consult the history offer flag"
        )
    }

    // MARK: - Helpers

    private func v23() throws -> Data {
        let file = try loadVectors()
        let hex = try XCTUnwrap(file.vectors.first(where: { $0.id == "V23" })?.hex)
        return try hexData(hex)
    }

    private func vectorKey() throws -> SymmetricKey {
        let file = try loadVectors()
        let hex = try XCTUnwrap(file.vectors.first(where: { $0.id == "V23" })?.fileChannelKey)
        return SymmetricKey(data: try hexData(hex))
    }

    private func knownOffering() throws -> CTHFVerify.Known {
        let file = try loadVectors()
        return CTHFVerify.Known(
            recipientDeviceId: try hexData(file.keys.receiverDeviceIdRaw),
            kyberKeyId: 7,
            senderIdentityPublic: try hexData(file.keys.offeringIdentityPublic),
            senderHybridPublic: try hexData(file.keys.hybridPublic),
            pin: .pinned(HistorySnapshotDisposition.qrFingerprint(
                identityPublic: try hexData(file.keys.offeringIdentityPublic),
                hybridPublic: try hexData(file.keys.hybridPublic)
            ))
        )
    }

    private func writeFixtureFile() throws -> URL {
        let header = try CTHFHeader.parse(try v23())
        var userId = header.userId
        if userId.count != 16 { userId = Data(repeating: 0x01, count: 16) }
        var recs: [HistoryRecord] = []
        var m = Construct_Client_History_V1_HistoryManifest()
        m.formatVersion = 1
        m.phase = 3
        m.userID = header.userId
        m.snapshotID = header.snapshotId
        recs.append(.manifest(m))
        var c = Construct_Client_History_V1_HistoryContact()
        c.userID = Data(repeating: 0x11, count: 16)
        c.displayName = "Peer"
        recs.append(.contact(c))
        recs.append(.end)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cth-\(UUID().uuidString).cthf")
        try CTHFEnvelope.write(to: url, header: header, records: recs, key: try vectorKey())
        return url
    }

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
        let receiverDeviceIdRaw: String
        enum CodingKeys: String, CodingKey {
            case hybridPublic = "hybrid_public"
            case offeringIdentityPublic = "offering_identity_public"
            case receiverDeviceIdRaw = "receiver_device_id_raw"
        }
    }
    private struct Vector: Decodable {
        let id: String
        let hex: String?
        let fileChannelKey: String?
        enum CodingKeys: String, CodingKey {
            case id, hex
            case fileChannelKey = "file_channel_key"
        }
    }

    private func loadVectors() throws -> VectorFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance/knst_history_snapshot.json")
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
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
