//
//  HistoryNearbyStream.swift
//  Construct Messenger
//
//  Record stream ↔ 64 KiB AAD chunks over a byte pipe. Handshake is separate.
//

import CryptoKit
import Foundation

struct HistoryStreamSession {
    var key: SymmetricKey
    var snapshotId: Data
    var userId: Data
}

enum HistoryNearbyStream {

    /// Encode records, chunk, seal, write. Does not pull the next record until the
    /// current chunk has been written.
    static func send(
        _ records: AsyncThrowingStream<HistoryRecord, Error>,
        over transport: HistoryByteTransport,
        session: HistoryStreamSession
    ) async throws {
        var pending = Data()
        pending.append(HistorySnapshotCodec.encodePreamble())
        var index: UInt32 = 0

        func flushFullChunks() async throws {
            while pending.count >= HistoryChunkCipher.plaintextSize {
                let slice = pending.prefix(HistoryChunkCipher.plaintextSize)
                pending.removeFirst(HistoryChunkCipher.plaintextSize)
                try await writeChunk(Data(slice), index: index, transport: transport, session: session)
                index += 1
            }
        }

        for try await record in records {
            pending.append(try HistorySnapshotCodec.encodeRecord(record))
            try await flushFullChunks()
            if record.isEnd { break }
        }
        if !pending.isEmpty {
            try await writeChunk(pending, index: index, transport: transport, session: session)
        }
        try await transport.send(HistoryChunkCipher.eof)
    }

    static func receive(
        over transport: HistoryByteTransport,
        session: HistoryStreamSession
    ) -> AsyncThrowingStream<HistoryRecord, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var reader = HistorySnapshotCodec.IncrementalReader()
                var index: UInt32 = 0
                do {
                    while true {
                        let lenBytes = try await transport.receiveExact(4)
                        let len = Int(lenBytes.withUnsafeBytes {
                            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
                        })
                        if len == 0 { break }
                        guard len <= HistoryChunkCipher.maxSealedSize else {
                            throw HistorySnapshotError.malformed
                        }
                        let sealed = try await transport.receiveExact(len)
                        let plain = try HistoryChunkCipher.open(
                            sealed,
                            key: session.key,
                            snapshotId: session.snapshotId,
                            userId: session.userId,
                            index: index
                        )
                        index += 1
                        for rec in try reader.push(plain) {
                            continuation.yield(rec)
                            if rec.isEnd {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    for rec in try reader.finish() {
                        continuation.yield(rec)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func writeChunk(
        _ plaintext: Data,
        index: UInt32,
        transport: HistoryByteTransport,
        session: HistoryStreamSession
    ) async throws {
        let sealed = try HistoryChunkCipher.seal(
            plaintext,
            key: session.key,
            snapshotId: session.snapshotId,
            userId: session.userId,
            index: index
        )
        try await transport.send(HistoryChunkCipher.frame(sealed))
    }
}
