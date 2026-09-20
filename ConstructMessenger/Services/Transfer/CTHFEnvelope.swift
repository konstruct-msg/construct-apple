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
        try write(to: url, header: header, key: key) { emit in
            for rec in records {
                try emit(rec)
            }
        }
    }

    /// Seal records to `url` as they are produced, holding at most one 64 KiB chunk.
    ///
    /// The whole-file form built the plaintext, then the ciphertext, then handed both to
    /// `Data.write` — three copies of a snapshot resident at once, which is what put a ceiling on
    /// phase-3 media. Here the only buffer that grows is `pending`, and it is drained every time it
    /// reaches a chunk.
    ///
    /// The file is written to a sibling temporary and moved into place, so a failure part-way
    /// leaves no half-sealed `.cthf` for the importer to find.
    static func write(
        to url: URL,
        header: CTHFHeader,
        key: SymmetricKey,
        producing: ((HistoryRecord) throws -> Void) throws -> Void
    ) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).cthf-part")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw HistorySnapshotError.malformed
        }
        let handle = try FileHandle(forWritingTo: tmp)
        var closed = false
        func closeHandle() {
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
        defer {
            closeHandle()
            try? fm.removeItem(at: tmp)   // no-op once the move below succeeded
        }

        var pending = Data()
        var index: UInt32 = 0

        func flush(all: Bool) throws {
            while pending.count >= HistoryChunkCipher.plaintextSize
                || (all && !pending.isEmpty) {
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
                index += 1
                try handle.write(contentsOf: HistoryChunkCipher.frame(sealed))
            }
        }

        try handle.write(contentsOf: header.serialize())
        pending.append(HistorySnapshotCodec.encodePreamble())
        try producing { rec in
            pending.append(try HistorySnapshotCodec.encodeRecord(rec))
            try flush(all: false)
        }
        try flush(all: true)
        try handle.write(contentsOf: HistoryChunkCipher.eof)
        closeHandle()

        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }

    static func readRecords(
        from url: URL,
        header: CTHFHeader,
        key: SymmetricKey
    ) throws -> [HistoryRecord] {
        var recs: [HistoryRecord] = []
        try readRecords(from: url, header: header, key: key) { recs.append($0) }
        return recs
    }

    /// Decrypt chunk by chunk and hand each record straight to `onRecord`.
    ///
    /// Nothing accumulates: one sealed chunk, its plaintext, and whatever records that chunk
    /// completed. A truncated file is `truncated`, a chunk that fails to open is the cipher's
    /// error — neither is reported as a short but valid snapshot.
    static func readRecords(
        from url: URL,
        header: CTHFHeader,
        key: SymmetricKey,
        onRecord: (HistoryRecord) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(CTT1V2Layout.cthfHeaderCount))
        var reader = HistorySnapshotCodec.IncrementalReader()
        var index: UInt32 = 0

        while true {
            guard let lenBytes = try handle.read(upToCount: 4) else { break }
            if lenBytes.isEmpty { break }
            guard lenBytes.count == 4 else { throw HistorySnapshotError.truncated }
            let len = Int(lenBytes.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            })
            if len == 0 { break }   // EOF frame
            guard len <= HistoryChunkCipher.maxSealedSize else {
                throw HistorySnapshotError.truncated
            }
            guard let sealed = try handle.read(upToCount: len), sealed.count == len else {
                throw HistorySnapshotError.truncated
            }
            let plain = try HistoryChunkCipher.open(
                sealed,
                key: key,
                snapshotId: header.snapshotId,
                userId: header.userId,
                index: index
            )
            index += 1
            for rec in try reader.push(plain) {
                try onRecord(rec)
            }
        }
        for rec in try reader.finish() {
            try onRecord(rec)
        }
    }

    /// Verify, read, import, delete on success. Leaves the file on failure.
    /// Read only the fixed-size header off the front of the file.
    static func readHeader(at url: URL) throws -> CTHFHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let front = try handle.read(upToCount: CTT1V2Layout.cthfHeaderCount),
              front.count == CTT1V2Layout.cthfHeaderCount else {
            throw HistorySnapshotError.truncated
        }
        return try CTHFHeader.parse(front)
    }

    static func importFile(
        at url: URL,
        expected: CTHFVerify.Known,
        key: SymmetricKey,
        expectedUserId: String,
        in context: NSManagedObjectContext
    ) throws -> HistoryImportSummary {
        let header = try readHeader(at: url)
        switch CTHFVerify.header(header, known: expected) {
        case .failure(let err):
            throw err
        case .success:
            break
        }
        var batch = HistorySnapshotImporter().makeBatch(
            expectedUserId: expectedUserId,
            in: context
        )
        try readRecords(from: url, header: header, key: key) { rec in
            try batch.apply(rec)
        }
        let summary = try batch.finish()
        try FileManager.default.removeItem(at: url)
        return summary
    }
}
