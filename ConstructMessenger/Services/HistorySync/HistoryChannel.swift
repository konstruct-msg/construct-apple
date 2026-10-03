//
//  HistoryChannel.swift
//  Construct Messenger
//
//  The glue between the core and the device for a history transfer: which of our devices the
//  directory says the other side is, and the file path — the offering device writes a CTHF
//  file for the new device, the new device opens one. The header, the key schedule, the
//  signatures, the checks and the chunk stream are the core's (`HistorySender` /
//  `HistoryReceiver`, construct-core `src/history/`); this file reads and writes bytes.
//

import CoreData
import Foundation

/// What `GetPreKeyBundles(own account, consumeOtpk: false)` says about one of our devices,
/// reduced to the four things a history transfer needs. `hybridPublic` and the Kyber SPK are
/// mandatory: a device without them refuses history (`no_hybrid_key`), it does not downgrade.
struct HistoryPeer: Equatable {
    let deviceIdHex: String
    let deviceIdRaw: Data
    let identityPublic: Data
    let hybridPublic: Data
    let kyberSPKPublic: Data
    let kyberSPKId: UInt32
}

extension HistoryPeer {
    /// The directory entry as the core's sender takes it.
    var coreKeys: HistoryPeerKeys {
        HistoryPeerKeys(
            identityPublic: identityPublic,
            hybridPublic: hybridPublic,
            kyberPrekeyPublic: kyberSPKPublic,
            kyberPrekeyId: kyberSPKId
        )
    }

    /// The keys a received frame is checked against.
    var knownKeys: HistoryKnownKeys {
        HistoryKnownKeys(identityPublic: identityPublic, hybridPublic: hybridPublic)
    }
}

/// This device, as a transfer names it. The keys are the core's and are not read here: a device
/// without a hybrid identity or a Kyber prekey is refused by the core (`local_keys_unavailable`).
struct HistoryLocalKeys {
    let userIdDashed: String
    /// The account's 16 raw UUID bytes: the chunk AAD and the manifest are bound to them.
    let userIdRaw: Data
    let deviceIdHex: String
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
              let deviceHex = KeychainManager.shared.loadDeviceID()
        else { throw HistoryChannelError.localKeysUnavailable }
        return HistoryLocalKeys(userIdDashed: userId, userIdRaw: userRaw, deviceIdHex: deviceHex)
    }

    /// The directory's answer for one of our own devices. `pinnedIdentity` is the Flow B
    /// `pubkey=` on the offering side; a bundle whose identity differs is `qr_pin_mismatch`,
    /// never a retry. nil means the directory is the only root (Flow A on the offering side —
    /// the new device pins us, not the reverse), and the log line says so.
    static func fetchPeerKeys(
        ownUserId: String,
        peerDeviceId: String,
        pinnedIdentity: Data?
    ) async throws -> HistoryPeer {
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
    static func peerKeys(from entry: DeviceBundleData, pinnedIdentity: Data?) throws -> HistoryPeer {
        let b = entry.bundle
        guard let raw = rawDeviceId(entry.deviceId) else {
            throw HistoryError.Malformed(message: "malformed")
        }
        guard !entry.hybridIdentityKey.isEmpty,
              let kyber = b.kyberPreKeyPublic, !kyber.isEmpty,
              let kyberId = b.kyberPreKeyId
        else { throw HistoryError.NoHybridKey(message: "no_hybrid_key") }
        // The device id is derived from the identity key; a bundle whose pair disagrees is not
        // this device's bundle, whatever the directory labelled it.
        guard deriveDeviceId(identityPublicKey: b.identityPublic) == entry.deviceId.lowercased() else {
            throw HistoryError.IdentityMismatch(message: "identity_mismatch")
        }
        if let pinned = pinnedIdentity {
            guard pinned == b.identityPublic else {
                throw HistoryError.QrPinMismatch(message: "qr_pin_mismatch")
            }
            Log.info("history_trust device=\(entry.deviceId.prefix(8))… root=qr_pubkey", category: "HistorySync")
        } else {
            Log.info("history_trust device=\(entry.deviceId.prefix(8))… root=bundle_only", category: "HistorySync")
        }
        return HistoryPeer(
            deviceIdHex: entry.deviceId.lowercased(),
            deviceIdRaw: raw,
            identityPublic: b.identityPublic,
            hybridPublic: entry.hybridIdentityKey,
            kyberSPKPublic: kyber,
            kyberSPKId: kyberId
        )
    }

    // MARK: - File: offering side

    /// Seal a phase-3 snapshot of `context` for `peer` into `url`, streaming: records and media
    /// pieces go through the core and its sealed chunks straight to disk, so memory holds one
    /// chunk, not the snapshot. Written to a sibling temporary and moved into place, so a failure
    /// leaves no half-sealed file for an importer to find.
    static func writeFile(
        to url: URL,
        peer: HistoryPeer,
        local: HistoryLocalKeys,
        context: NSManagedObjectContext
    ) async throws -> (snapshotId: Data, counters: HistoryEncodeCounters) {
        let sender = try CryptoManager.shared.historyCore().historyOfferFile(
            userId: local.userIdRaw,
            peer: peer.coreKeys
        )
        let identity = HistorySnapshotIdentity.make(
            userId: local.userIdDashed,
            sourceDeviceId: local.deviceIdHex,
            snapshotId: sender.snapshotId()
        )
        let (items, counters) = try await context.perform {
            let encoder = HistorySnapshotEncoder(identity: identity)
            return (try encoder.collect(phase: 3, context: context), encoder.counters)
        }

        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).cthf-part")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw HistoryError.Malformed(message: "malformed")
        }
        defer { try? fm.removeItem(at: tmp) }   // a no-op once the move below succeeded
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: sender.firstFrame())
            try await HistoryCoreStream.send(items, through: sender) { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
        Log.info(
            "history_file_written snapshot=\(HistorySnapshotIdentity.tag(sender.snapshotId())) records=\(items.count) to=\(peer.deviceIdHex.prefix(8))…",
            category: "HistorySync"
        )
        return (sender.snapshotId(), counters)
    }

    static func suggestedFileName(forSnapshot snapshotId: Data) -> String {
        "konstruct-history-" + HistorySnapshotIdentity.tag(snapshotId) + ".cthf"
    }

    // MARK: - File: new device

    /// Open a file sealed to this device and import it. The core reads the header, stops for the
    /// source device's keys — asked of our own account's directory, never taken from the file —
    /// checks them and the link QR's pin, and only then decapsulates and opens the chunks. The
    /// file is deleted only after the import returns; every refusal leaves it in place.
    static func importFile(
        at url: URL,
        local: HistoryLocalKeys,
        pin: HistoryQRPin,
        context: NSManagedObjectContext
    ) async throws -> HistoryImportSummary {
        let receiver = try CryptoManager.shared.historyCore().historyReceive(userId: local.userIdRaw, fromFile: true)
        let sink = HistoryImportSink(expectedUserId: local.userIdDashed, context: context)
        let outcome: HistoryCoreStream.Outcome
        do {
            outcome = try await HistoryCoreStream.receive(
                from: try HistoryFileSource(url: url),
                into: receiver,
                sink: sink,
                pin: pin,
                resolve: { deviceIdHex in
                    try await fetchPeerKeys(
                        ownUserId: local.userIdDashed,
                        peerDeviceId: deviceIdHex,
                        pinnedIdentity: nil
                    ).knownKeys
                },
                reply: nil
            )
        } catch {
            Log.error("history_file_refused reason=\(error.localizedDescription)", category: "HistorySync")
            throw error
        }
        guard case .imported(let summary, _) = outcome else {
            // A file has no skip; a header that says otherwise was refused above.
            throw HistoryError.Malformed(message: "malformed")
        }
        try FileManager.default.removeItem(at: url)
        Log.info(
            "history_snapshot_done source=file applied=\(summary.applied) conflicts=\(summary.conflictKeepExisting) skipped=\(summary.skipped.values.reduce(0, +))",
            category: "HistorySync"
        )
        NotificationCenter.default.post(name: .historyImported, object: nil)
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
        case let e as HistoryError:
            switch e {
            case .QrPinMismatch: return NSLocalizedString("history_sync_qr_pin_mismatch", comment: "")
            case .QrPinAbsent: return NSLocalizedString("history_sync_qr_pin_absent", comment: "")
            case .KemKeyIdMismatch: return NSLocalizedString("history_sync_kem_key_id_mismatch", comment: "")
            case .NoHybridKey: return NSLocalizedString("history_sync_no_hybrid_key", comment: "")
            case .V1RefusedForHistory: return NSLocalizedString("transfer_error_history_v1_refused", comment: "")
            case .LocalKeysUnavailable: return NSLocalizedString("history_sync_local_keys_unavailable", comment: "")
            case .UserMismatch: return NSLocalizedString("history_sync_user_mismatch", comment: "")
            case .Malformed, .Truncated, .UnknownVersion, .RecordOrder, .EnvelopeManifestMismatch,
                 .IdentityMismatch, .SignatureInvalid, .ChunkOpenFailed:
                return NSLocalizedString("transfer_error_corrupt", comment: "")
            }
        case let e as HistoryChannelError:
            switch e {
            case .localKeysUnavailable: return NSLocalizedString("history_sync_local_keys_unavailable", comment: "")
            case .peerNotInDirectory: return NSLocalizedString("history_sync_peer_not_found", comment: "")
            }
        case let e as NearbyTransferError:
            return e.errorDescription ?? NSLocalizedString("transfer_error_connection", comment: "")
        default:
            return error.localizedDescription
        }
    }
}
