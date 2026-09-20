//
//  CTT1V2Verify.swift
//  Construct Messenger
//
//  Receiver verify order (spec §4): ids → key id → known keys → QR pin →
//  signature → then decapsulate. Decapsulation is the caller's job.
//

import Foundation

enum CTT1V2Verify {

    struct Known {
        var identityPublic: Data
        var hybridPublic: Data
        var localDeviceId: Data
        var kyberKeyId: UInt32
        /// What the link QR pinned. `.absent` refuses history (`qr_pin_absent`);
        /// `.bundleOnly` is Flow B's named residual and is accepted.
        var pin: HistoryQRPin
    }

    static func opening(
        _ frame: CTT1V2Opening,
        known: Known
    ) -> Result<Void, CTT1V2Error> {
        // 1. ids
        let derived = deriveDeviceId(identityPublicKey: [UInt8](frame.senderIdentityPub))
        let framedHex = frame.senderDeviceId.map { String(format: "%02x", $0) }.joined()
        guard derived == framedHex else { return .failure(.identityMismatch) }
        guard HistorySnapshotDisposition.equal(frame.receiverDeviceId, known.localDeviceId) else {
            return .failure(.identityMismatch)
        }

        // 2. key id
        guard frame.receiverKyberKeyId == known.kyberKeyId else {
            return .failure(.kemKeyIdMismatch)
        }

        // 3. known keys from GetPreKeyBundles
        guard !known.hybridPublic.isEmpty else { return .failure(.noHybridKey) }
        guard HistorySnapshotDisposition.equal(frame.senderIdentityPub, known.identityPublic),
              HistorySnapshotDisposition.equal(frame.senderHybridPub, known.hybridPublic) else {
            return .failure(.identityMismatch)
        }

        // 4. QR pin
        switch known.pin {
        case .absent:
            return .failure(.qrPinAbsent)
        case .bundleOnly:
            break
        case .pinned(let fp):
            guard HistorySnapshotDisposition.qrPinMatches(
                identityPublic: frame.senderIdentityPub,
                hybridPublic: frame.senderHybridPub,
                fp: fp
            ) else {
                return .failure(.qrPinMismatch)
            }
        }

        // 5. signature (tagged). Decapsulate only after this returns success.
        do {
            let ok = try hybridVerify(
                publicKey: [UInt8](frame.senderHybridPub),
                message: [UInt8](frame.taggedMessage),
                signature: [UInt8](frame.signature)
            )
            guard ok else { return .failure(.signatureInvalid) }
        } catch {
            return .failure(.signatureInvalid)
        }
        return .success(())
    }

    static func reply(
        _ frame: CTT1V2Reply,
        opening: CTT1V2Opening,
        knownIdentity: Data,
        knownHybrid: Data
    ) -> Result<Void, CTT1V2Error> {
        let derived = deriveDeviceId(identityPublicKey: [UInt8](frame.receiverIdentityPub))
        let framedHex = opening.receiverDeviceId.map { String(format: "%02x", $0) }.joined()
        guard derived == framedHex else { return .failure(.identityMismatch) }
        guard !knownHybrid.isEmpty else { return .failure(.noHybridKey) }
        guard HistorySnapshotDisposition.equal(frame.receiverIdentityPub, knownIdentity),
              HistorySnapshotDisposition.equal(frame.receiverHybridPub, knownHybrid) else {
            return .failure(.identityMismatch)
        }
        let message = frame.taggedMessage(
            senderEphPub: opening.senderEphPub,
            snapshotId: opening.snapshotId,
            senderDeviceId: opening.senderDeviceId,
            receiverDeviceId: opening.receiverDeviceId,
            kemCt: opening.kemCt
        )
        do {
            let ok = try hybridVerify(
                publicKey: [UInt8](frame.receiverHybridPub),
                message: [UInt8](message),
                signature: [UInt8](frame.signature)
            )
            guard ok else { return .failure(.signatureInvalid) }
        } catch {
            return .failure(.signatureInvalid)
        }
        return .success(())
    }

    static func historyAccepts(prefix: CTT1V2Prefix) -> Result<Void, CTT1V2Error> {
        switch prefix.type {
        case .backup:
            return .failure(.malformed)
        case .historySync, .historySyncSkipped:
            if prefix.version == CTT1V2Layout.versionV1 {
                return .failure(.v1RefusedForHistory)
            }
            if prefix.version == CTT1V2Layout.versionV2 {
                return .success(())
            }
            return .failure(.malformed)
        }
    }
}
