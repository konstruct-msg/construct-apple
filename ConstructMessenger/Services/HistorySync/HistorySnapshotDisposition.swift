//
//  HistorySnapshotDisposition.swift
//  Construct Messenger
//
//  Pure decisions for CTH1. No I/O. SHA-256 via CommonCrypto (HistorySync
//  must not import CryptoKit — transfer crypto is stage 5).
//

import Foundation
import CommonCrypto

enum HistoryConflictPolicy: Equatable {
    case keepExisting
    case insert
}

enum HistorySnapshotError: Error, Equatable {
    case malformed
    case truncated
    case unknownVersion
    case userMismatch
    case recordOrder
    case envelopeManifestMismatch
    case payloadTooLarge
    case unsetBody
}

enum HistoryRecordType {
    static let end: UInt8 = 0x00
    static let manifest: UInt8 = 0x01
    static let contact: UInt8 = 0x02
    static let chat: UInt8 = 0x03
    static let message: UInt8 = 0x04
    static let reaction: UInt8 = 0x05
    static let peer: UInt8 = 0x06
    static let call: UInt8 = 0x07
    static let media: UInt8 = 0x08
    static let reservedLow: UInt8 = 0x09
    static let reservedHigh: UInt8 = 0x0D
}

enum HistorySnapshotDisposition {

    static func accept(
        manifest: Construct_Client_History_V1_HistoryManifest,
        expectedUserId: Data
    ) -> Result<Void, HistorySnapshotError> {
        guard manifest.formatVersion == 1 else { return .failure(.unknownVersion) }
        guard (1...3).contains(manifest.phase) else { return .failure(.malformed) }
        guard equal(manifest.userID, expectedUserId) else { return .failure(.userMismatch) }
        return .success(())
    }

    static func messageConflict(existing: Bool) -> HistoryConflictPolicy {
        existing ? .keepExisting : .insert
    }

    /// Upsert key is the peer's account id. Chat.id is minted per device.
    static func chatUpsertKey(otherUserId: Data) -> Data {
        otherUserId
    }

    /// Share flags only go false→true. A profile-true on the receiver is not clobbered.
    static func contactShareFlag(snapshot: Bool, alreadyTrueOnReceiver: Bool) -> Bool {
        alreadyTrueOnReceiver || snapshot
    }

    /// Core derivation, not a second SHA-256. device_id is 32 lowercase hex.
    static func peerDeviceHintAcceptable(deviceId: String, identityKey: Data) -> Bool {
        let derived = deriveDeviceId(identityPublicKey: [UInt8](identityKey))
        return derived == deviceId.lowercased()
    }

    static func lowercaseMessageId(_ id: String) -> String {
        id.lowercased()
    }

    /// Rank-monotonic order. Unknown types are skipped by the codec and must not
    /// be passed as `previous`. Manifest only first. Rank never goes backwards, so
    /// a reaction then a message fails; an empty message section then reactions
    /// (manifest → reaction) is allowed.
    static func recordOrderAcceptable(phase: UInt32, previous: UInt8?, incoming: UInt8) -> Bool {
        let inc = classify(incoming)
        if inc == .unknown { return true }
        guard let prevByte = previous else {
            return inc == .manifest
        }
        if inc == .manifest { return false }
        switch inc {
        case .meta, .message, .reaction:
            if phase == 2 { return false }
        case .media:
            if phase == 1 { return false }
        default:
            break
        }
        return rank(inc) >= rank(classify(prevByte))
    }

    static func envelopeMatchesManifest(
        envelopeSnapshotId: Data,
        envelopeUserId: Data,
        manifest: Construct_Client_History_V1_HistoryManifest
    ) -> Bool {
        equal(envelopeSnapshotId, manifest.snapshotID) && equal(envelopeUserId, manifest.userID)
    }

    /// 32 hex chars = SHA256("cth1:" || dashed UUID || 32-hex device id)[0:16].
    static func discoveryTag(userIdDashed: String, newDeviceIdHex: String) -> String {
        let preimage = "cth1:" + userIdDashed + newDeviceIdHex
        return hexPrefix16(sha256(Data(preimage.utf8)))
    }

    /// Bonjour instance name: SHA256("ctt1_instance:" || tag)[0:16] hex.
    static func discoveryInstanceName(tag: String) -> String {
        hexPrefix16(sha256(Data(("ctt1_instance:" + tag).utf8)))
    }

    /// Flow A pin: SHA256(identity_pub || hybrid_pub), 32 bytes.
    static func qrFingerprint(identityPublic: Data, hybridPublic: Data) -> Data {
        var preimage = Data()
        preimage.append(identityPublic)
        preimage.append(hybridPublic)
        return Data(sha256(preimage))
    }

    /// Flow A pin: SHA256(identity_pub || hybrid_pub) equals the 32-byte fp.
    static func qrPinMatches(identityPublic: Data, hybridPublic: Data, fp: Data) -> Bool {
        guard fp.count == 32 else { return false }
        return equal(qrFingerprint(identityPublic: identityPublic, hybridPublic: hybridPublic), fp)
    }

    // MARK: - Classify

    fileprivate enum Kind {
        case manifest, meta, message, reaction, media, end, unknown
    }

    fileprivate static func classify(_ type: UInt8) -> Kind {
        switch type {
        case HistoryRecordType.manifest: return .manifest
        case HistoryRecordType.contact, HistoryRecordType.chat,
             HistoryRecordType.peer, HistoryRecordType.call: return .meta
        case HistoryRecordType.message: return .message
        case HistoryRecordType.reaction: return .reaction
        case HistoryRecordType.media: return .media
        case HistoryRecordType.end: return .end
        default: return .unknown
        }
    }

    private static func rank(_ kind: Kind) -> Int {
        switch kind {
        case .manifest: return 0
        case .meta: return 1
        case .message: return 2
        case .reaction: return 3
        case .media: return 4
        case .end: return 5
        case .unknown: return -1
        }
    }

    /// Length-mismatch fails closed. Equal length is XOR-accumulated so a mismatch
    /// does not return on the first differing byte.
    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    static func sha256(_ data: Data) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash
    }

    private static func hexPrefix16(_ digest: [UInt8]) -> String {
        digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
