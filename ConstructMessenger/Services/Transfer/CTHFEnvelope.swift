//
//  CTHFEnvelope.swift
//  Construct Messenger
//
//  File fallback: CTHF header then the same 64 KiB AAD chunks as nearby.
//  Verify order: recipient id → Kyber key id → known keys → QR pin → signature
//  → then decapsulate. Delete the file after a successful import.
//

import CoreData
import CryptoKit
import Foundation

struct CTHFHeader: Equatable {
    var userId: Data
    var recipientDeviceId: Data
    var sourceDeviceId: Data
    var snapshotId: Data
    var senderEphPub: Data
    var senderIdentityPub: Data
    var senderHybridPub: Data
    var recipientKyberKeyId: UInt32
    var kemCt: Data
    var signature: Data

    var kyberKeyIdLE: Data {
        var le = recipientKyberKeyId.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    var taggedMessage: Data {
        var t = CTT1V2Layout.fileTag
        t.append(userId)
        t.append(recipientDeviceId)
        t.append(sourceDeviceId)
        t.append(snapshotId)
        t.append(senderEphPub)
        t.append(senderIdentityPub)
        t.append(senderHybridPub)
        t.append(kyberKeyIdLE)
        t.append(kemCt)
        return t
    }

    static func parse(_ data: Data) throws -> CTHFHeader {
        let bytes = data.startIndex == 0 ? data : Data(data)
        guard bytes.count == CTT1V2Layout.cthfHeaderCount else { throw CTT1V2Error.malformed }
        guard bytes[0..<4] == CTT1V2Layout.cthfMagic else { throw CTT1V2Error.malformed }
        guard bytes[4] == CTT1V2Layout.cthfVersion else { throw CTT1V2Error.malformed }
        var o = 5
        func take(_ n: Int) -> Data {
            let slice = Data(bytes[o..<(o + n)])
            o += n
            return slice
        }
        let user = take(16)
        let recipient = take(16)
        let source = take(16)
        let snapshot = take(16)
        let eph = take(CTT1V2Layout.ephPubCount)
        let identity = take(CTT1V2Layout.identityPubCount)
        let hybrid = take(CTT1V2Layout.hybridPubCount)
        let keyIdBytes = take(CTT1V2Layout.kyberKeyIdCount)
        let kem = take(CTT1V2Layout.kemCtCount)
        let sig = take(CTT1V2Layout.hybridSigCount)
        guard o == bytes.count else { throw CTT1V2Error.malformed }
        let keyId = keyIdBytes.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        return CTHFHeader(
            userId: user,
            recipientDeviceId: recipient,
            sourceDeviceId: source,
            snapshotId: snapshot,
            senderEphPub: eph,
            senderIdentityPub: identity,
            senderHybridPub: hybrid,
            recipientKyberKeyId: keyId,
            kemCt: kem,
            signature: sig
        )
    }

    func serialize() throws -> Data {
        guard userId.count == 16,
              recipientDeviceId.count == 16,
              sourceDeviceId.count == 16,
              snapshotId.count == 16,
              senderEphPub.count == CTT1V2Layout.ephPubCount,
              senderIdentityPub.count == CTT1V2Layout.identityPubCount,
              senderHybridPub.count == CTT1V2Layout.hybridPubCount,
              kemCt.count == CTT1V2Layout.kemCtCount,
              signature.count == CTT1V2Layout.hybridSigCount
        else { throw CTT1V2Error.malformed }
        var out = Data()
        out.append(CTT1V2Layout.cthfMagic)
        out.append(CTT1V2Layout.cthfVersion)
        out.append(userId)
        out.append(recipientDeviceId)
        out.append(sourceDeviceId)
        out.append(snapshotId)
        out.append(senderEphPub)
        out.append(senderIdentityPub)
        out.append(senderHybridPub)
        out.append(kyberKeyIdLE)
        out.append(kemCt)
        out.append(signature)
        guard out.count == CTT1V2Layout.cthfHeaderCount else { throw CTT1V2Error.malformed }
        return out
    }
}

enum CTHFVerify {
    struct Known {
        var recipientDeviceId: Data
        var kyberKeyId: UInt32
        var senderIdentityPublic: Data
        var senderHybridPublic: Data
        var pin: HistoryQRPin
    }

    static func header(_ header: CTHFHeader, known: Known) -> Result<Void, CTT1V2Error> {
        guard HistorySnapshotDisposition.equal(header.recipientDeviceId, known.recipientDeviceId) else {
            return .failure(.identityMismatch)
        }
        guard header.recipientKyberKeyId == known.kyberKeyId else {
            return .failure(.kemKeyIdMismatch)
        }
        guard !known.senderHybridPublic.isEmpty else { return .failure(.noHybridKey) }
        guard HistorySnapshotDisposition.equal(header.senderIdentityPub, known.senderIdentityPublic),
              HistorySnapshotDisposition.equal(header.senderHybridPub, known.senderHybridPublic) else {
            return .failure(.identityMismatch)
        }
        switch known.pin {
        case .absent:
            return .failure(.qrPinAbsent)
        case .bundleOnly:
            break
        case .pinned(let fp):
            guard HistorySnapshotDisposition.qrPinMatches(
                identityPublic: header.senderIdentityPub,
                hybridPublic: header.senderHybridPub,
                fp: fp
            ) else { return .failure(.qrPinMismatch) }
        }
        do {
            let ok = try hybridVerify(
                publicKey: [UInt8](header.senderHybridPub),
                message: [UInt8](header.taggedMessage),
                signature: [UInt8](header.signature)
            )
            guard ok else { return .failure(.signatureInvalid) }
        } catch {
            return .failure(.signatureInvalid)
        }
        return .success(())
    }
}

enum CTHFEnvelope {
    /// Write header then chunked records. Caller supplies the already-derived channel key
    /// (production derives it after encapsulate; tests inject the vector key).
    static func write(
        to url: URL,
        header: CTHFHeader,
        records: [HistoryRecord],
        key: SymmetricKey
    ) throws {
        var body = try header.serialize()
        var pending = HistorySnapshotCodec.encodePreamble()
        for rec in records {
            pending.append(try HistorySnapshotCodec.encodeRecord(rec))
        }
        var index: UInt32 = 0
        while !pending.isEmpty {
            let take = min(HistoryChunkCipher.plaintextSize, pending.count)
            let slice = Data(pending.prefix(take))
            pending.removeFirst(take)
            let sealed = try HistoryChunkCipher.seal(
                slice,
                key: key,
                snapshotId: header.snapshotId,
                userId: header.userId,
                index: index
            )
            body.append(HistoryChunkCipher.frame(sealed))
            index += 1
        }
        body.append(HistoryChunkCipher.eof)
        try body.write(to: url, options: .atomic)
    }

    static func readRecords(
        from url: URL,
        header: CTHFHeader,
        key: SymmetricKey
    ) throws -> [HistoryRecord] {
        let data = try Data(contentsOf: url)
        guard data.count >= CTT1V2Layout.cthfHeaderCount else { throw HistorySnapshotError.truncated }
        var offset = CTT1V2Layout.cthfHeaderCount
        var reader = HistorySnapshotCodec.IncrementalReader()
        var recs: [HistoryRecord] = []
        var index: UInt32 = 0
        while offset + 4 <= data.count {
            let len = Int(data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            })
            offset += 4
            if len == 0 { break }
            guard len <= HistoryChunkCipher.maxSealedSize, offset + len <= data.count else {
                throw HistorySnapshotError.truncated
            }
            let sealed = data.subdata(in: offset..<(offset + len))
            offset += len
            let plain = try HistoryChunkCipher.open(
                sealed,
                key: key,
                snapshotId: header.snapshotId,
                userId: header.userId,
                index: index
            )
            index += 1
            recs += try reader.push(plain)
        }
        recs += try reader.finish()
        return recs
    }

    /// Verify, read, import, delete on success. Leaves the file on failure.
    static func importFile(
        at url: URL,
        expected: CTHFVerify.Known,
        key: SymmetricKey,
        expectedUserId: String,
        in context: NSManagedObjectContext
    ) throws -> HistoryImportSummary {
        let data = try Data(contentsOf: url)
        guard data.count >= CTT1V2Layout.cthfHeaderCount else { throw HistorySnapshotError.truncated }
        let header = try CTHFHeader.parse(data.prefix(CTT1V2Layout.cthfHeaderCount))
        switch CTHFVerify.header(header, known: expected) {
        case .failure(let err):
            throw err
        case .success:
            break
        }
        let recs = try readRecords(from: url, header: header, key: key)
        let summary = try HistorySnapshotImporter().importRecords(
            recs,
            expectedUserId: expectedUserId,
            in: context
        )
        try FileManager.default.removeItem(at: url)
        return summary
    }
}
