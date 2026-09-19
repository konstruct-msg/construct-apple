//
//  CTT1V2Frames.swift
//  Construct Messenger
//
//  Hostile-input first. Read 46 bytes, then 6529 more only if version == 0x02.
//  Lengths come from CTT1V2Layout field sums.
//

import Foundation

struct CTT1V2Prefix {
    let version: UInt8
    let senderEphPub: Data
    let type: NearbyTransferService.TransferType
    let payloadLength: Int

    static func parse(_ frame: Data) throws -> CTT1V2Prefix {
        let bytes = frame.startIndex == 0 ? frame : Data(frame)
        guard bytes.count == CTT1V2Layout.prefixCount else { throw CTT1V2Error.malformed }
        guard bytes[0..<4] == CTT1V2Layout.magic else { throw CTT1V2Error.malformed }
        let version = bytes[4]
        guard version == CTT1V2Layout.versionV1 || version == CTT1V2Layout.versionV2 else {
            throw CTT1V2Error.malformed
        }
        guard let type = NearbyTransferService.TransferType(rawValue: bytes[37]) else {
            throw CTT1V2Error.malformed
        }
        let announced = bytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 38, as: UInt64.self).littleEndian
        }
        guard announced <= CTT1V2Layout.maxPayloadBytes else { throw CTT1V2Error.malformed }
        return CTT1V2Prefix(
            version: version,
            senderEphPub: Data(bytes[5..<37]),
            type: type,
            payloadLength: Int(announced)
        )
    }
}

struct CTT1V2Opening: Equatable {
    var senderEphPub: Data
    var type: NearbyTransferService.TransferType
    var payloadLength: Int
    var senderIdentityPub: Data
    var senderHybridPub: Data
    var snapshotId: Data
    var senderDeviceId: Data
    var receiverDeviceId: Data
    var receiverKyberKeyId: UInt32
    var kemCt: Data
    var signature: Data

    var payloadLenLE: Data {
        var le = UInt64(payloadLength).littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    var kyberKeyIdLE: Data {
        var le = receiverKyberKeyId.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    /// Signed transcript: eph || identity || hybrid || snapshot || senderDev ||
    /// receiverDev || kyberKeyId_le4 || kemCt || type || payloadLen_le8
    var signedTranscript: Data {
        var t = Data()
        t.append(senderEphPub)
        t.append(senderIdentityPub)
        t.append(senderHybridPub)
        t.append(snapshotId)
        t.append(senderDeviceId)
        t.append(receiverDeviceId)
        t.append(kyberKeyIdLE)
        t.append(kemCt)
        t.append(type.rawValue)
        t.append(payloadLenLE)
        return t
    }

    var taggedMessage: Data {
        CTT1V2Layout.senderTag + signedTranscript
    }

    static func parse(_ frame: Data) throws -> CTT1V2Opening {
        let bytes = frame.startIndex == 0 ? frame : Data(frame)
        guard bytes.count == CTT1V2Layout.openingCount else { throw CTT1V2Error.malformed }
        let prefix = try CTT1V2Prefix.parse(Data(bytes[0..<CTT1V2Layout.prefixCount]))
        guard prefix.version == CTT1V2Layout.versionV2 else { throw CTT1V2Error.malformed }
        switch prefix.type {
        case .historySync, .historySyncSkipped: break
        case .backup: throw CTT1V2Error.malformed
        }

        var o = CTT1V2Layout.prefixCount
        func take(_ n: Int) -> Data {
            let slice = Data(bytes[o..<(o + n)])
            o += n
            return slice
        }
        let identity = take(CTT1V2Layout.identityPubCount)
        let hybrid = take(CTT1V2Layout.hybridPubCount)
        let snapshot = take(CTT1V2Layout.snapshotIdCount)
        let senderDev = take(CTT1V2Layout.deviceIdCount)
        let receiverDev = take(CTT1V2Layout.deviceIdCount)
        let keyIdBytes = take(CTT1V2Layout.kyberKeyIdCount)
        let kemCt = take(CTT1V2Layout.kemCtCount)
        let sig = take(CTT1V2Layout.hybridSigCount)
        guard o == bytes.count else { throw CTT1V2Error.malformed }

        let keyId = keyIdBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }

        if prefix.type == .historySync, kemCt.allSatisfy({ $0 == 0 }) {
            throw CTT1V2Error.malformed
        }
        if prefix.type == .historySyncSkipped, !kemCt.allSatisfy({ $0 == 0 }) {
            throw CTT1V2Error.malformed
        }

        return CTT1V2Opening(
            senderEphPub: prefix.senderEphPub,
            type: prefix.type,
            payloadLength: prefix.payloadLength,
            senderIdentityPub: identity,
            senderHybridPub: hybrid,
            snapshotId: snapshot,
            senderDeviceId: senderDev,
            receiverDeviceId: receiverDev,
            receiverKyberKeyId: keyId,
            kemCt: kemCt,
            signature: sig
        )
    }

    func serialize() throws -> Data {
        guard senderEphPub.count == CTT1V2Layout.ephPubCount,
              senderIdentityPub.count == CTT1V2Layout.identityPubCount,
              senderHybridPub.count == CTT1V2Layout.hybridPubCount,
              snapshotId.count == CTT1V2Layout.snapshotIdCount,
              senderDeviceId.count == CTT1V2Layout.deviceIdCount,
              receiverDeviceId.count == CTT1V2Layout.deviceIdCount,
              kemCt.count == CTT1V2Layout.kemCtCount,
              signature.count == CTT1V2Layout.hybridSigCount
        else { throw CTT1V2Error.malformed }
        if type == .historySync, kemCt.allSatisfy({ $0 == 0 }) {
            throw CTT1V2Error.malformed
        }
        var out = Data()
        out.append(CTT1V2Layout.magic)
        out.append(CTT1V2Layout.versionV2)
        out.append(senderEphPub)
        out.append(type.rawValue)
        out.append(payloadLenLE)
        out.append(senderIdentityPub)
        out.append(senderHybridPub)
        out.append(snapshotId)
        out.append(senderDeviceId)
        out.append(receiverDeviceId)
        out.append(kyberKeyIdLE)
        out.append(kemCt)
        out.append(signature)
        guard out.count == CTT1V2Layout.openingCount else { throw CTT1V2Error.malformed }
        return out
    }
}

struct CTT1V2Reply: Equatable {
    var receiverEphPub: Data
    var receiverIdentityPub: Data
    var receiverHybridPub: Data
    var signature: Data

    func taggedMessage(
        senderEphPub: Data,
        snapshotId: Data,
        senderDeviceId: Data,
        receiverDeviceId: Data,
        kemCt: Data
    ) -> Data {
        var t = CTT1V2Layout.receiverTag
        t.append(receiverEphPub)
        t.append(senderEphPub)
        t.append(receiverIdentityPub)
        t.append(receiverHybridPub)
        t.append(snapshotId)
        t.append(senderDeviceId)
        t.append(receiverDeviceId)
        t.append(kemCt)
        return t
    }

    static func parse(_ frame: Data) throws -> CTT1V2Reply {
        let bytes = frame.startIndex == 0 ? frame : Data(frame)
        guard bytes.count == CTT1V2Layout.replyCount else { throw CTT1V2Error.malformed }
        var o = 0
        func take(_ n: Int) -> Data {
            let slice = Data(bytes[o..<(o + n)])
            o += n
            return slice
        }
        return CTT1V2Reply(
            receiverEphPub: take(CTT1V2Layout.ephPubCount),
            receiverIdentityPub: take(CTT1V2Layout.identityPubCount),
            receiverHybridPub: take(CTT1V2Layout.hybridPubCount),
            signature: take(CTT1V2Layout.hybridSigCount)
        )
    }

    func serialize() throws -> Data {
        guard receiverEphPub.count == CTT1V2Layout.ephPubCount,
              receiverIdentityPub.count == CTT1V2Layout.identityPubCount,
              receiverHybridPub.count == CTT1V2Layout.hybridPubCount,
              signature.count == CTT1V2Layout.hybridSigCount
        else { throw CTT1V2Error.malformed }
        var out = Data()
        out.append(receiverEphPub)
        out.append(receiverIdentityPub)
        out.append(receiverHybridPub)
        out.append(signature)
        guard out.count == CTT1V2Layout.replyCount else { throw CTT1V2Error.malformed }
        return out
    }
}
