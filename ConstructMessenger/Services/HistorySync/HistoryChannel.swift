//
//  HistoryChannel.swift
//  Construct Messenger
//
//  The glue between the pure pieces and the device: which keys each side holds, how the
//  offering device seals a CTHF file to the new device, how the new device opens one.
//  Nearby (CTT1 v2) uses the same key material with the other salt; only the carrier of
//  `kem_ct` differs. Crypto decisions are the core's: encapsulate / decapsulate / sign_hybrid /
//  hybrid_verify are called, never rebuilt (plan §10). The KEM is ML-KEM-1024 to the receiving
//  device's Kyber SPK since PQXDH v2; the receiving side decapsulates inside the core, which holds
//  the key's seed and never hands it out.
//

import CoreData
import CryptoKit
import Foundation

/// What `GetPreKeyBundles(own account, consumeOtpk: false)` says about one of our devices,
/// reduced to the four things a history transfer needs. `hybridPublic` and the Kyber SPK are
/// mandatory: a device without them refuses history (`no_hybrid_key`), it does not downgrade.
struct HistoryPeerKeys: Equatable {
    let deviceIdHex: String
    let deviceIdRaw: Data
    let identityPublic: Data
    let hybridPublic: Data
    let kyberSPKPublic: Data
    let kyberSPKId: UInt32
}

/// This device's half. Read once per transfer, never stored beyond the call.
struct HistoryLocalKeys {
    let userIdDashed: String
    let userIdRaw: Data
    let deviceIdHex: String
    let deviceIdRaw: Data
    let identityPrivate: Data
    let identityPublic: Data
    let hybridPublic: Data
    /// Our current Kyber SPK, the key a peer encapsulates to. Its secret stays in the core:
    /// `CryptoManager.kyberPrekeyDecapsulate`.
    let kyberSPKId: UInt32
}

enum HistoryChannelError: Error, Equatable {
    /// This device has no identity, no Kyber SPK or no hybrid key in the core.
    case localKeysUnavailable
    /// The bundle fetch returned no entry for the device we were asked to reach.
    case peerNotInDirectory
}

enum HistoryChannel {

    // MARK: - Keys

    static func localKeys() throws -> HistoryLocalKeys {
        guard let userId = KeychainManager.shared.loadUserID(),
              let userRaw = HistoryAccountID.raw(userId),
              let deviceHex = KeychainManager.shared.loadDeviceID(),
              let deviceRaw = Self.rawDeviceId(deviceHex),
              let identityPrivate = KeychainManager.shared.loadDeviceIdentityKey(),
              identityPrivate.count == 32,
              let hybridPublic = CryptoManager.shared.hybridIdentityPublicKey(),
              hybridPublic.count == CTT1V2Layout.hybridPubCount
        else { throw HistoryChannelError.localKeysUnavailable }
        let identityPublic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: identityPrivate)
            .publicKey.rawRepresentation
        guard let kyberSPK = try? CryptoManager.shared.currentKyberSpkUpload() else {
            throw HistoryChannelError.localKeysUnavailable
        }
        return HistoryLocalKeys(
            userIdDashed: userId,
            userIdRaw: userRaw,
            deviceIdHex: deviceHex,
            deviceIdRaw: deviceRaw,
            identityPrivate: identityPrivate,
            identityPublic: identityPublic,
            hybridPublic: hybridPublic,
            kyberSPKId: kyberSPK.keyId
        )
    }

    /// The directory's answer for one of our own devices. `pinnedIdentity` is the Flow B
    /// `pubkey=` on the offering side; a bundle whose identity differs is `qr_pin_mismatch`,
    /// never a retry. nil means the directory is the only root (Flow A on the offering side —
    /// the new device pins us, not the reverse), and the log line says so.
    static func fetchPeerKeys(
        ownUserId: String,
        peerDeviceId: String,
        pinnedIdentity: Data?
    ) async throws -> HistoryPeerKeys {
        let bundles = try await KeyServiceClient.shared.getPreKeyBundles(
            userId: ownUserId,
            deviceIds: [peerDeviceId],
            consumeOneTimePrekey: false
        )
        guard let entry = bundles.first(where: { $0.deviceId == peerDeviceId }) else {
            throw HistoryChannelError.peerNotInDirectory
        }
        return try peerKeys(from: entry, pinnedIdentity: pinnedIdentity)
    }

    /// Pure reduction of a bundle, so the refusal rules are testable without a server.
    static func peerKeys(from entry: DeviceBundleData, pinnedIdentity: Data?) throws -> HistoryPeerKeys {
        let b = entry.bundle
        guard b.identityPublic.count == CTT1V2Layout.identityPubCount,
              let raw = rawDeviceId(entry.deviceId)
        else { throw CTT1V2Error.malformed }
        guard entry.hybridIdentityKey.count == CTT1V2Layout.hybridPubCount,
              let kyber = b.kyberPreKeyPublic, !kyber.isEmpty,
              let kyberId = b.kyberPreKeyId
        else { throw CTT1V2Error.noHybridKey }
        // The device id is derived from the identity key; a bundle whose pair disagrees is not
        // this device's bundle, whatever the directory labelled it.
        guard deriveDeviceId(identityPublicKey: [UInt8](b.identityPublic)) == entry.deviceId.lowercased() else {
            throw CTT1V2Error.identityMismatch
        }
        if let pinned = pinnedIdentity {
            guard HistorySnapshotDisposition.equal(pinned, b.identityPublic) else {
                throw CTT1V2Error.qrPinMismatch
            }
            Log.info("history_trust device=\(entry.deviceId.prefix(8))… root=qr_pubkey", category: "HistorySync")
        } else {
            Log.info("history_trust device=\(entry.deviceId.prefix(8))… root=bundle_only", category: "HistorySync")
        }
        return HistoryPeerKeys(
            deviceIdHex: entry.deviceId.lowercased(),
            deviceIdRaw: raw,
            identityPublic: b.identityPublic,
            hybridPublic: entry.hybridIdentityKey,
            kyberSPKPublic: kyber,
            kyberSPKId: kyberId
        )
    }

    // MARK: - File: offering side

    /// Seal a phase-3 snapshot of `context` for `peer` into `url`. Header per spec §5: ephemeral
    /// X25519 × the new device's identity, ML-KEM-1024 to its Kyber SPK, HKDF with the file salt,
    /// hybrid signature from the core over the tagged header.
    ///
    /// Collects the records before writing — the CTHF writer is not streaming yet (open question
    /// in the 2026-09-18 session note). Must be called on `context`'s queue.
    static func writeFile(
        to url: URL,
        peer: HistoryPeerKeys,
        local: HistoryLocalKeys,
        context: NSManagedObjectContext
    ) throws -> (identity: HistorySnapshotIdentity, counters: HistoryEncodeCounters, records: Int) {
        let identity = HistorySnapshotIdentity.make(userId: local.userIdDashed, sourceDeviceId: local.deviceIdHex)
        let encoder = HistorySnapshotEncoder(identity: identity)
        let records = try encoder.collectAll(context: context)

        let eph = Curve25519.KeyAgreement.PrivateKey()
        let peerIdentity = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.identityPublic)
        let ecdh = try eph.sharedSecretFromKeyAgreement(with: peerIdentity)
            .withUnsafeBytes { Data($0) }
        let kem = try mlkem1024Encapsulate(publicKey: [UInt8](peer.kyberSPKPublic))
        let key = TransferCrypto.deriveChannelKey(
            ecdh: ecdh,
            kemSharedSecret: Data(kem.sharedSecret),
            salt: .file,
            snapshotId: identity.snapshotId
        )

        var header = CTHFHeader(
            userId: local.userIdRaw,
            recipientDeviceId: peer.deviceIdRaw,
            sourceDeviceId: local.deviceIdRaw,
            snapshotId: identity.snapshotId,
            senderEphPub: eph.publicKey.rawRepresentation,
            senderIdentityPub: local.identityPublic,
            senderHybridPub: local.hybridPublic,
            recipientKyberKeyId: peer.kyberSPKId,
            kemCt: Data(kem.ciphertext),
            signature: Data()
        )
        header.signature = try CryptoManager.shared.signHybrid(header.taggedMessage)

        try CTHFEnvelope.write(to: url, header: header, records: records, key: key)
        Log.info(
            "history_file_written snapshot=\(identity.snapshotId.prefix(4).map { String(format: "%02x", $0) }.joined()) records=\(records.count) to=\(peer.deviceIdHex.prefix(8))…",
            category: "HistorySync"
        )
        return (identity, encoder.counters, records.count)
    }

    static func suggestedFileName(for identity: HistorySnapshotIdentity) -> String {
        "konstruct-history-" + identity.snapshotId.prefix(4).map { String(format: "%02x", $0) }.joined() + ".cthf"
    }

    // MARK: - File: new device

    /// Parse, verify against our own keys, the directory's keys for the source device and the
    /// link QR's pin, then decapsulate and import. The file is deleted only after the importer
    /// returns; every refusal leaves it in place. The directory fetch happens first; the import
    /// step runs on `context`'s queue.
    /// The header alone, so the directory can be asked before the file is opened for real.
    static func readHeader(at url: URL) throws -> CTHFHeader {
        try CTHFEnvelope.readHeader(at: url)
    }

    static func importFile(
        at url: URL,
        local: HistoryLocalKeys,
        pin: HistoryQRPin,
        context: NSManagedObjectContext
    ) async throws -> HistoryImportSummary {
        let header = try readHeader(at: url)

        // Whose file: the source device must be one of ours, and the directory is asked for its
        // keys — never the header's own copy of them.
        let sourceHex = header.sourceDeviceId.map { String(format: "%02x", $0) }.joined()
        let peer = try await fetchPeerKeys(
            ownUserId: local.userIdDashed,
            peerDeviceId: sourceHex,
            pinnedIdentity: nil
        )
        let known = CTHFVerify.Known(
            recipientDeviceId: local.deviceIdRaw,
            kyberKeyId: local.kyberSPKId,
            senderIdentityPublic: peer.identityPublic,
            senderHybridPublic: peer.hybridPublic,
            pin: pin
        )
        if case .failure(let reason) = CTHFVerify.header(header, known: known) {
            Log.error("history_file_refused reason=\(reason)", category: "HistorySync")
            throw reason
        }
        if case .bundleOnly = pin {
            Log.info("history_file_trust root=bundle_only (Flow B residual)", category: "HistorySync")
        }

        // Verified: only now touch the secrets.
        let ourPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: local.identityPrivate)
        let senderEph = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: header.senderEphPub)
        let ecdh = try ourPriv.sharedSecretFromKeyAgreement(with: senderEph).withUnsafeBytes { Data($0) }
        let kemSS = try CryptoManager.shared.kyberPrekeyDecapsulate(
            keyId: local.kyberSPKId,
            ciphertext: header.kemCt
        )
        let key = TransferCrypto.deriveChannelKey(
            ecdh: ecdh,
            kemSharedSecret: kemSS,
            salt: .file,
            snapshotId: header.snapshotId
        )

        let expectedUserId = local.userIdDashed
        let summary = try await context.perform {
            try CTHFEnvelope.importFile(
                at: url,
                expected: known,
                key: key,
                expectedUserId: expectedUserId,
                in: context
            )
        }
        Log.info(
            "history_snapshot_done source=file applied=\(summary.applied) conflicts=\(summary.conflictKeepExisting) skipped=\(summary.skipped.values.reduce(0, +))",
            category: "HistorySync"
        )
        return summary
    }

    // MARK: - Helpers

    static func rawDeviceId(_ hex: String) -> Data? {
        guard hex.count == 32 else { return nil }
        var out = Data(capacity: 16)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }
}

// MARK: - User-facing reasons

/// One place that turns a refusal into the sentence the user sees. Every named reason from
/// the spec's observability table has its own line; anything else is "corrupted, try again".
enum HistoryTransferUserMessage {
    static func text(for error: Error) -> String {
        switch error {
        case let e as CTT1V2Error:
            switch e {
            case .qrPinMismatch: return NSLocalizedString("history_sync_qr_pin_mismatch", comment: "")
            case .qrPinAbsent: return NSLocalizedString("history_sync_qr_pin_absent", comment: "")
            case .kemKeyIdMismatch: return NSLocalizedString("history_sync_kem_key_id_mismatch", comment: "")
            case .noHybridKey: return NSLocalizedString("history_sync_no_hybrid_key", comment: "")
            case .v1RefusedForHistory: return NSLocalizedString("transfer_error_history_v1_refused", comment: "")
            case .malformed, .identityMismatch, .signatureInvalid:
                return NSLocalizedString("transfer_error_corrupt", comment: "")
            }
        case let e as HistoryChannelError:
            switch e {
            case .localKeysUnavailable: return NSLocalizedString("history_sync_local_keys_unavailable", comment: "")
            case .peerNotInDirectory: return NSLocalizedString("history_sync_peer_not_found", comment: "")
            }
        case let e as HistorySnapshotError:
            switch e {
            case .userMismatch: return NSLocalizedString("history_sync_user_mismatch", comment: "")
            default: return NSLocalizedString("transfer_error_corrupt", comment: "")
            }
        case let e as NearbyTransferError:
            return e.errorDescription ?? NSLocalizedString("transfer_error_connection", comment: "")
        default:
            return error.localizedDescription
        }
    }
}
