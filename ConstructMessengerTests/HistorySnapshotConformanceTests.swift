//
//  HistorySnapshotConformanceTests.swift
//  ConstructMessengerTests
//
//  Every vector in knst_history_snapshot.json, by name. A vector this file
//  does not switch on reddens — that is how a new V25 cannot land as bytes
//  nobody classifies.
//

import CryptoKit
import XCTest
@testable import Construct_Messenger

final class HistorySnapshotConformanceTests: XCTestCase {

    private struct VectorFile: Decodable {
        let constants: Constants
        let keys: Keys
        let vectors: [Vector]
        enum CodingKeys: String, CodingKey {
            case constants = "$constants"
            case keys = "$keys"
            case vectors
        }
    }

    private struct Constants: Decodable {
        let maxRecordBytes: UInt64
        let ctt1V2OpeningLen: Int
        let ctt1V2ReplyLen: Int
        let cthfHeaderLen: Int
        let snapshotId: String
        let userId: String
        enum CodingKeys: String, CodingKey {
            case maxRecordBytes = "max_record_bytes"
            case ctt1V2OpeningLen = "ctt1_v2_opening_len"
            case ctt1V2ReplyLen = "ctt1_v2_reply_len"
            case cthfHeaderLen = "cthf_header_len"
            case snapshotId = "snapshot_id"
            case userId = "user_id"
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
        let name: String
        let kind: String
        let expect: String
        let hex: String?
        let byteLen: Int?
        let records: [String]?
        let phase: UInt32?
        let envelopeSnapshotId: String?
        let manifestSnapshotId: String?
        let preimageUtf8: String?
        let tag: String?
        let instanceName: String?
        let preimage: String?
        let fp: String?
        let chunk0Combined: String?
        let chunk0Plaintext: String?
        let fileChannelKey: String?
        let currentKyberKeyId: UInt32?
        enum CodingKeys: String, CodingKey {
            case id, name, kind, expect, hex, records, phase, tag, fp
            case byteLen = "byte_len"
            case envelopeSnapshotId = "envelope_snapshot_id"
            case manifestSnapshotId = "manifest_snapshot_id"
            case preimageUtf8 = "preimage_utf8"
            case instanceName = "instance_name"
            case preimage
            case chunk0Combined = "chunk0_combined"
            case chunk0Plaintext = "chunk0_plaintext"
            case fileChannelKey = "file_channel_key"
            case currentKyberKeyId = "current_kyber_key_id"
        }
    }

    private func load() throws -> VectorFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Networking/gRPC/Generated/conformance")
            .appendingPathComponent("knst_history_snapshot.json")
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(VectorFile.self, from: data)
        XCTAssertEqual(file.vectors.count, 24, "vectors look truncated — every assertion would pass")
        return file
    }

    private func hexData(_ hex: String) throws -> Data {
        var s = hex
        if s.count % 2 != 0 { throw HistorySnapshotError.malformed }
        var out = Data()
        out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { throw HistorySnapshotError.malformed }
            out.append(b)
            i = j
        }
        return out
    }

    private func names(of records: [HistoryRecord]) -> [String] {
        records.map { rec in
            switch rec {
            case .manifest: return "manifest"
            case .contact: return "contact"
            case .chat: return "chat"
            case .message: return "message"
            case .reaction: return "reaction"
            case .peerDevice: return "peer"
            case .call: return "call"
            case .mediaBlob: return "media"
            case .skipped: return "unknown"
            case .end: return "end"
            }
        }
    }

    /// Mutation: drop a case from this switch — that vector is then "not classified".
    func testEveryVectorIsClassifiedByName() throws {
        let file = try load()
        var seen = Set<String>()
        for v in file.vectors {
            seen.insert(v.id)
            switch v.id {
            case "V1", "V2", "V3", "V5", "V7", "V8", "V9", "V10":
                try assertDecodeOK(v)
            case "V4":
                try assertPhaseZeroFails(v)
            case "V6":
                try assertBadPeerHint(v)
            case "V11", "V12", "V13":
                try assertRecordOrder(v)
            case "V14":
                try assertEnvelopeMismatch(v, constants: file.constants)
            case "V15":
                try assertPayloadCap(v)
            case "V16":
                try assertUnknownSkipped(v)
            case "V17":
                try assertDiscovery(v, keys: file.keys)
            case "V18":
                try assertQRPin(v, keys: file.keys)
            case "V19":
                try assertOpeningVerifies(v, keys: file.keys, expectedLen: file.constants.ctt1V2OpeningLen)
            case "V20":
                try assertReplyParses(v, expectedLen: file.constants.ctt1V2ReplyLen)
            case "V21":
                try assertOpeningEd25519OnlyFails(v, keys: file.keys, expectedLen: file.constants.ctt1V2OpeningLen)
            case "V22":
                try assertOpeningZeroKemCtMalformed(v, expectedLen: file.constants.ctt1V2OpeningLen)
            case "V23":
                try assertCTHFHeaderVerifies(v, keys: file.keys, expectedLen: file.constants.cthfHeaderLen)
            case "V24":
                try assertCTHFStaleKeyId(v, keys: file.keys, expectedLen: file.constants.cthfHeaderLen)
            default:
                XCTFail("\(v.id) \(v.name): no case — a new vector arrived and nobody classified it")
            }
        }
        for i in 1...24 {
            XCTAssertTrue(seen.contains("V\(i)"), "V\(i) missing from the vendored JSON")
        }
    }

    // MARK: - CTH1

    private func assertDecodeOK(_ v: Vector) throws {
        let data = try hexData(try XCTUnwrap(v.hex))
        XCTAssertFalse(data.contains(LocalMessagePayload.magic), "\(v.id): CTM1 in a CTH1 vector")
        let recs = try HistorySnapshotCodec.decode(data)
        if let want = v.records {
            XCTAssertEqual(names(of: recs), want, v.id)
        }
        if let phase = v.phase, case .manifest(let m) = recs.first {
            XCTAssertEqual(m.phase, phase, v.id)
            if case .failure(let err) = HistorySnapshotDisposition.accept(manifest: m, expectedUserId: m.userID) {
                XCTFail("\(v.id): accept failed \(err)")
            }
        }
    }

    private func assertPhaseZeroFails(_ v: Vector) throws {
        let data = try hexData(try XCTUnwrap(v.hex))
        XCTAssertThrowsError(try HistorySnapshotCodec.decode(data), v.id) { err in
            XCTAssertEqual(err as? HistorySnapshotError, .malformed, v.id)
        }
    }

    private func assertBadPeerHint(_ v: Vector) throws {
        let recs = try HistorySnapshotCodec.decode(try hexData(try XCTUnwrap(v.hex)))
        guard case .peerDevice(let hint) = recs.first(where: { if case .peerDevice = $0 { return true }; return false }) else {
            return XCTFail("\(v.id): no peer record")
        }
        XCTAssertFalse(
            HistorySnapshotDisposition.peerDeviceHintAcceptable(
                deviceId: hint.deviceID,
                identityKey: hint.identityKey
            ),
            "\(v.id): a mismatched hint must not be acceptable"
        )
    }

    private func assertRecordOrder(_ v: Vector) throws {
        XCTAssertThrowsError(try HistorySnapshotCodec.decode(try hexData(try XCTUnwrap(v.hex))), v.id) { err in
            XCTAssertEqual(err as? HistorySnapshotError, .recordOrder, v.id)
        }
    }

    private func assertEnvelopeMismatch(_ v: Vector, constants: Constants) throws {
        let recs = try HistorySnapshotCodec.decode(try hexData(try XCTUnwrap(v.hex)))
        guard case .manifest(let m) = recs.first else {
            return XCTFail("\(v.id): no manifest")
        }
        let envelopeId = try hexData(try XCTUnwrap(v.envelopeSnapshotId))
        XCTAssertFalse(
            HistorySnapshotDisposition.envelopeMatchesManifest(
                envelopeSnapshotId: envelopeId,
                envelopeUserId: m.userID,
                manifest: m
            ),
            "\(v.id): envelope snapshot_id must not match"
        )
        XCTAssertEqual(m.snapshotID, try hexData(try XCTUnwrap(v.manifestSnapshotId)))
        XCTAssertEqual(m.snapshotID, try hexData(constants.snapshotId))
    }

    private func assertPayloadCap(_ v: Vector) throws {
        XCTAssertEqual(HistorySnapshotCodec.maxRecordBytes, 512 * 1024 * 1024)
        XCTAssertThrowsError(try HistorySnapshotCodec.decode(try hexData(try XCTUnwrap(v.hex))), v.id) { err in
            XCTAssertEqual(err as? HistorySnapshotError, .payloadTooLarge, v.id)
        }
    }

    private func assertUnknownSkipped(_ v: Vector) throws {
        let recs = try HistorySnapshotCodec.decode(try hexData(try XCTUnwrap(v.hex)))
        XCTAssertEqual(names(of: recs), v.records, v.id)
        guard case .skipped(let type, _) = recs[1] else {
            return XCTFail("\(v.id): expected skipped reserved type")
        }
        XCTAssertEqual(type, HistoryRecordType.reservedLow)
    }

    private func assertDiscovery(_ v: Vector, keys: Keys) throws {
        let preimage = try XCTUnwrap(v.preimageUtf8)
        let dashed = "00000000-0000-4000-8000-000000000001"
        let tag = HistorySnapshotDisposition.discoveryTag(
            userIdDashed: dashed,
            newDeviceIdHex: keys.receiverDeviceIdRaw
        )
        XCTAssertEqual(tag, v.tag, v.id)
        XCTAssertEqual(
            HistorySnapshotDisposition.discoveryInstanceName(tag: tag),
            v.instanceName,
            v.id
        )
        XCTAssertTrue(preimage.hasPrefix("cth1:"))
        let rawUuidHex = "00000000000040008000000000000001"
        XCTAssertNotEqual(
            HistorySnapshotDisposition.discoveryTag(
                userIdDashed: rawUuidHex,
                newDeviceIdHex: keys.receiverDeviceIdRaw
            ),
            tag,
            "dashed-UUID vs raw-UUID discovery tags must differ"
        )
    }

    private func assertQRPin(_ v: Vector, keys: Keys) throws {
        let identity = try hexData(keys.offeringIdentityPublic)
        let hybrid = try hexData(keys.hybridPublic)
        let fp = try hexData(try XCTUnwrap(v.fp))
        XCTAssertTrue(
            HistorySnapshotDisposition.qrPinMatches(
                identityPublic: identity,
                hybridPublic: hybrid,
                fp: fp
            ),
            v.id
        )
        XCTAssertEqual(fp.count, 32)
    }

    private func assertOpeningVerifies(_ v: Vector, keys: Keys, expectedLen: Int) throws {
        try assertFrame(v, magic: "CTT1", expectedLen: expectedLen)
        let data = try hexData(try XCTUnwrap(v.hex))
        XCTAssertEqual(data[4], 0x02, v.id)
        let opening = try CTT1V2Opening.parse(data)
        XCTAssertEqual(opening.type, .historySync)
        XCTAssertEqual(try opening.serialize(), data, "\(v.id): serialize is the inverse of parse")
        let known = CTT1V2Verify.Known(
            identityPublic: try hexData(keys.offeringIdentityPublic),
            hybridPublic: try hexData(keys.hybridPublic),
            localDeviceId: try hexData(keys.receiverDeviceIdRaw),
            kyberKeyId: 7,
            qrFp: HistorySnapshotDisposition.qrFingerprint(
                identityPublic: try hexData(keys.offeringIdentityPublic),
                hybridPublic: try hexData(keys.hybridPublic)
            )
        )
        if case .failure(let err) = CTT1V2Verify.opening(opening, known: known) {
            XCTFail("\(v.id): verify failed \(err)")
        }
        let untagged = try hybridVerify(
            publicKey: [UInt8](opening.senderHybridPub),
            message: [UInt8](opening.signedTranscript),
            signature: [UInt8](opening.signature)
        )
        XCTAssertFalse(untagged, "\(v.id): signature must fail without the domain tag")
    }

    private func assertReplyParses(_ v: Vector, expectedLen: Int) throws {
        try assertFrame(v, magic: nil, expectedLen: expectedLen)
        let data = try hexData(try XCTUnwrap(v.hex))
        let reply = try CTT1V2Reply.parse(data)
        XCTAssertEqual(try reply.serialize(), data, "\(v.id): serialize is the inverse of parse")
    }

    private func assertOpeningEd25519OnlyFails(_ v: Vector, keys: Keys, expectedLen: Int) throws {
        try assertFrame(v, magic: "CTT1", expectedLen: expectedLen)
        let opening = try CTT1V2Opening.parse(try hexData(try XCTUnwrap(v.hex)))
        let known = CTT1V2Verify.Known(
            identityPublic: try hexData(keys.offeringIdentityPublic),
            hybridPublic: try hexData(keys.hybridPublic),
            localDeviceId: try hexData(keys.receiverDeviceIdRaw),
            kyberKeyId: 7,
            qrFp: HistorySnapshotDisposition.qrFingerprint(
                identityPublic: try hexData(keys.offeringIdentityPublic),
                hybridPublic: try hexData(keys.hybridPublic)
            )
        )
        if case .failure(let err) = CTT1V2Verify.opening(opening, known: known) {
            XCTAssertEqual(err, .signatureInvalid, v.id)
        } else {
            XCTFail("\(v.id): Ed25519-only signature must not verify")
        }
    }

    private func assertCTHFHeaderVerifies(_ v: Vector, keys: Keys, expectedLen: Int) throws {
        try assertFrame(v, magic: "CTHF", expectedLen: expectedLen)
        XCTAssertEqual(CTT1V2Layout.cthfHeaderCount, expectedLen)
        let data = try hexData(try XCTUnwrap(v.hex))
        let header = try CTHFHeader.parse(data)
        XCTAssertEqual(try header.serialize(), data, "\(v.id): serialize is the inverse of parse")
        let known = CTHFVerify.Known(
            recipientDeviceId: try hexData(keys.receiverDeviceIdRaw),
            kyberKeyId: 7,
            senderIdentityPublic: try hexData(keys.offeringIdentityPublic),
            senderHybridPublic: try hexData(keys.hybridPublic),
            qrFp: HistorySnapshotDisposition.qrFingerprint(
                identityPublic: try hexData(keys.offeringIdentityPublic),
                hybridPublic: try hexData(keys.hybridPublic)
            )
        )
        if case .failure(let err) = CTHFVerify.header(header, known: known) {
            XCTFail("\(v.id): verify failed \(err)")
        }
        if let keyHex = v.fileChannelKey, let combinedHex = v.chunk0Combined, let plainHex = v.chunk0Plaintext {
            let key = SymmetricKey(data: try hexData(keyHex))
            let opened = try HistoryChunkCipher.open(
                try hexData(combinedHex),
                key: key,
                snapshotId: header.snapshotId,
                userId: header.userId,
                index: 0
            )
            XCTAssertEqual(opened, try hexData(plainHex), v.id)
        }
    }

    private func assertCTHFStaleKeyId(_ v: Vector, keys: Keys, expectedLen: Int) throws {
        try assertFrame(v, magic: "CTHF", expectedLen: expectedLen)
        let header = try CTHFHeader.parse(try hexData(try XCTUnwrap(v.hex)))
        let known = CTHFVerify.Known(
            recipientDeviceId: try hexData(keys.receiverDeviceIdRaw),
            kyberKeyId: v.currentKyberKeyId ?? 7,
            senderIdentityPublic: try hexData(keys.offeringIdentityPublic),
            senderHybridPublic: try hexData(keys.hybridPublic),
            qrFp: nil
        )
        if case .failure(let err) = CTHFVerify.header(header, known: known) {
            XCTAssertEqual(err, .kemKeyIdMismatch, v.id)
        } else {
            XCTFail("\(v.id): stale Kyber key id must fail")
        }
    }

    private func assertOpeningZeroKemCtMalformed(_ v: Vector, expectedLen: Int) throws {
        try assertFrame(v, magic: "CTT1", expectedLen: expectedLen)
        XCTAssertThrowsError(try CTT1V2Opening.parse(try hexData(try XCTUnwrap(v.hex))), v.id) { err in
            XCTAssertEqual(err as? CTT1V2Error, .malformed, v.id)
        }
    }

    private func assertFrame(_ v: Vector, magic: String?, expectedLen: Int) throws {
        let data = try hexData(try XCTUnwrap(v.hex))
        XCTAssertEqual(data.count, expectedLen, v.id)
        XCTAssertEqual(v.byteLen, expectedLen, v.id)
        if let magic {
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), magic, v.id)
        }
    }

    /// Codec/disposition stay store-agnostic. Importer and encoder (stage 3/4) are
    /// the Core Data projection; transfer crypto is still stage 5.
    func testHistorySyncSourcesDoNotImportCoreDataOrCryptoKit() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/HistorySync")
        let pure = [
            "HistorySnapshotCodec.swift",
            "HistorySnapshotDisposition.swift",
            "HistoryBodyCodec.swift",
            "HistoryAccountID.swift"
        ]
        for name in pure {
            let url = dir.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            let imports = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertFalse(imports.contains("import CoreData"), name)
            XCTAssertFalse(imports.contains("import CryptoKit"), name)
        }
    }
}
