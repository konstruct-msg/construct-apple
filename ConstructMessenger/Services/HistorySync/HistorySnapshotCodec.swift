//
//  HistorySnapshotCodec.swift
//  Construct Messenger
//
//  CTH1 stream reader/writer. Enforces maxRecordBytes before allocating.
//  No Core Data, no CryptoKit.
//

import Foundation
import SwiftProtobuf

enum HistoryRecord: Equatable {
    case manifest(Construct_Client_History_V1_HistoryManifest)
    case contact(Construct_Client_History_V1_HistoryContact)
    case chat(Construct_Client_History_V1_HistoryChat)
    case message(Construct_Client_History_V1_HistoryMessage)
    case reaction(Construct_Client_History_V1_HistoryReaction)
    case peerDevice(Construct_Client_History_V1_HistoryPeerDevice)
    case call(Construct_Client_History_V1_HistoryCall)
    case mediaBlob(Construct_Client_History_V1_HistoryMediaBlob)
    /// Unknown / reserved type. Payload kept so a writer is the inverse of a reader.
    case skipped(type: UInt8, payload: Data)
    case end

    var type: UInt8 {
        switch self {
        case .manifest: return HistoryRecordType.manifest
        case .contact: return HistoryRecordType.contact
        case .chat: return HistoryRecordType.chat
        case .message: return HistoryRecordType.message
        case .reaction: return HistoryRecordType.reaction
        case .peerDevice: return HistoryRecordType.peer
        case .call: return HistoryRecordType.call
        case .mediaBlob: return HistoryRecordType.media
        case .skipped(let type, _): return type
        case .end: return HistoryRecordType.end
        }
    }

    var isEnd: Bool {
        if case .end = self { return true }
        return false
    }
}

enum HistorySnapshotCodec {
    static let magic = Data([0x43, 0x54, 0x48, 0x31]) // "CTH1"
    static let version: UInt8 = 0x01
    /// 512 MiB. Hostile payload_len above this is malformed — do not allocate.
    static let maxRecordBytes: UInt64 = 512 * 1024 * 1024

    static func decode(_ data: Data) throws -> [HistoryRecord] {
        var reader = Reader(data: data)
        var out: [HistoryRecord] = []
        while let rec = try reader.next() {
            out.append(rec)
            if rec.isEnd { break }
        }
        return out
    }

    static func encode(_ records: [HistoryRecord]) throws -> Data {
        var out = Data()
        out.append(magic)
        out.append(version)
        var sawEnd = false
        for rec in records {
            try append(rec, to: &out)
            if rec.isEnd { sawEnd = true }
        }
        if !sawEnd { out.append(HistoryRecordType.end) }
        return out
    }

    static func makeStream(from data: Data) -> AsyncThrowingStream<HistoryRecord, Error> {
        AsyncThrowingStream { continuation in
            var reader = Reader(data: data)
            do {
                while let rec = try reader.next() {
                    continuation.yield(rec)
                    if rec.isEnd { break }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - Reader

    struct Reader {
        private let bytes: Data
        private var offset: Int
        private var phase: UInt32?
        private var previousKnown: UInt8?

        init(data: Data) {
            bytes = data.startIndex == 0 ? data : Data(data)
            offset = 0
            phase = nil
            previousKnown = nil
        }

        mutating func next() throws -> HistoryRecord? {
            if offset == 0 {
                try consumePreamble()
            }
            guard offset < bytes.count else {
                throw HistorySnapshotError.truncated
            }
            let type = bytes[offset]
            offset += 1
            if type == HistoryRecordType.end {
                if offset != bytes.count {
                    throw HistorySnapshotError.malformed
                }
                return .end
            }
            guard offset + 8 <= bytes.count else {
                throw HistorySnapshotError.truncated
            }
            let payloadLen = readUInt64LE(bytes, at: offset)
            offset += 8
            if payloadLen > maxRecordBytes {
                throw HistorySnapshotError.payloadTooLarge
            }
            let remaining = bytes.count - offset
            guard payloadLen <= UInt64(remaining) else {
                throw HistorySnapshotError.truncated
            }
            let len = Int(payloadLen)
            let payload = bytes.subdata(in: offset..<(offset + len))
            offset += len

            let record = try decodePayload(type: type, payload: payload)
            try checkOrder(record)
            return record
        }

        private mutating func consumePreamble() throws {
            guard bytes.count >= 6 else { throw HistorySnapshotError.truncated }
            guard bytes[0..<4] == HistorySnapshotCodec.magic else {
                throw HistorySnapshotError.malformed
            }
            guard bytes[4] == HistorySnapshotCodec.version else {
                throw HistorySnapshotError.unknownVersion
            }
            offset = 5
        }

        private mutating func checkOrder(_ record: HistoryRecord) throws {
            if case .skipped = record { return }
            let incoming = record.type
            if incoming == HistoryRecordType.manifest {
                guard let manifest = {
                    if case .manifest(let m) = record { return m }
                    return nil
                }() else { return }
                switch HistorySnapshotDisposition.accept(manifest: manifest, expectedUserId: manifest.userID) {
                case .failure(let err) where err == .unknownVersion || err == .malformed:
                    throw err
                default:
                    break
                }
                phase = manifest.phase
            }
            let phaseNow = phase ?? 0
            guard HistorySnapshotDisposition.recordOrderAcceptable(
                phase: phaseNow,
                previous: previousKnown,
                incoming: incoming
            ) else {
                throw HistorySnapshotError.recordOrder
            }
            previousKnown = incoming
        }
    }

    // MARK: - Payload

    private static func decodePayload(type: UInt8, payload: Data) throws -> HistoryRecord {
        do {
            switch type {
            case HistoryRecordType.manifest:
                return .manifest(try Construct_Client_History_V1_HistoryManifest(serializedBytes: payload))
            case HistoryRecordType.contact:
                return .contact(try Construct_Client_History_V1_HistoryContact(serializedBytes: payload))
            case HistoryRecordType.chat:
                return .chat(try Construct_Client_History_V1_HistoryChat(serializedBytes: payload))
            case HistoryRecordType.message:
                let msg = try Construct_Client_History_V1_HistoryMessage(serializedBytes: payload)
                switch HistoryBodyCodec.disposition(of: msg) {
                case .malformed:
                    throw HistorySnapshotError.unsetBody
                case .unknownBody:
                    return .skipped(type: type, payload: payload)
                case .ok:
                    return .message(msg)
                }
            case HistoryRecordType.reaction:
                return .reaction(try Construct_Client_History_V1_HistoryReaction(serializedBytes: payload))
            case HistoryRecordType.peer:
                return .peerDevice(try Construct_Client_History_V1_HistoryPeerDevice(serializedBytes: payload))
            case HistoryRecordType.call:
                return .call(try Construct_Client_History_V1_HistoryCall(serializedBytes: payload))
            case HistoryRecordType.media:
                return .mediaBlob(try Construct_Client_History_V1_HistoryMediaBlob(serializedBytes: payload))
            default:
                return .skipped(type: type, payload: payload)
            }
        } catch let err as HistorySnapshotError {
            throw err
        } catch {
            throw HistorySnapshotError.malformed
        }
    }

    private static func append(_ record: HistoryRecord, to out: inout Data) throws {
        if case .end = record {
            out.append(HistoryRecordType.end)
            return
        }
        let payload: Data
        switch record {
        case .manifest(let m): payload = try m.serializedData()
        case .contact(let c): payload = try c.serializedData()
        case .chat(let c): payload = try c.serializedData()
        case .message(let m): payload = try m.serializedData()
        case .reaction(let r): payload = try r.serializedData()
        case .peerDevice(let p): payload = try p.serializedData()
        case .call(let c): payload = try c.serializedData()
        case .mediaBlob(let b): payload = try b.serializedData()
        case .skipped(_, let raw): payload = raw
        case .end: return
        }
        let len = UInt64(payload.count)
        guard len <= maxRecordBytes else { throw HistorySnapshotError.payloadTooLarge }
        out.append(record.type)
        var le = len.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        out.append(payload)
    }
}

private func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
    data.withUnsafeBytes { raw in
        raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
    }
}
