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
        var reader = IncrementalReader()
        var out = try reader.push(data)
        out += try reader.finish()
        return out
    }

    static func encode(_ records: [HistoryRecord]) throws -> Data {
        var out = encodePreamble()
        var sawEnd = false
        for rec in records {
            out.append(try encodeRecord(rec))
            if rec.isEnd { sawEnd = true }
        }
        if !sawEnd { out.append(HistoryRecordType.end) }
        return out
    }

    static func encodePreamble() -> Data {
        var out = Data()
        out.append(magic)
        out.append(version)
        return out
    }

    static func encodeRecord(_ record: HistoryRecord) throws -> Data {
        var out = Data()
        try append(record, to: &out)
        return out
    }

    static func makeStream(from data: Data) -> AsyncThrowingStream<HistoryRecord, Error> {
        AsyncThrowingStream { continuation in
            var reader = IncrementalReader()
            do {
                for rec in try reader.push(data) { continuation.yield(rec) }
                for rec in try reader.finish() { continuation.yield(rec) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Cap on unparsed bytes: one max record plus one nearby chunk. Do not allocate more.
    static var maxAccumulatorBytes: Int { Int(maxRecordBytes) + 65_536 }

    /// Feed-as-you-go reader. Incomplete records wait; `finish()` turns leftover into `truncated`.
    struct IncrementalReader {
        private var buffer = Data()
        private var preambleDone = false
        private var phase: UInt32?
        private var previousKnown: UInt8?
        private var sawEnd = false

        mutating func push(_ data: Data) throws -> [HistoryRecord] {
            guard !sawEnd else {
                if !data.isEmpty { throw HistorySnapshotError.malformed }
                return []
            }
            if !data.isEmpty { buffer.append(data) }
            if buffer.count > HistorySnapshotCodec.maxAccumulatorBytes {
                throw HistorySnapshotError.payloadTooLarge
            }
            return try drain(requireComplete: false)
        }

        mutating func finish() throws -> [HistoryRecord] {
            let recs = try drain(requireComplete: true)
            if !sawEnd { throw HistorySnapshotError.truncated }
            return recs
        }

        private mutating func drain(requireComplete: Bool) throws -> [HistoryRecord] {
            var out: [HistoryRecord] = []
            if buffer.startIndex != 0 { buffer = Data(buffer) }
            if !preambleDone {
                if buffer.count < 5 {
                    if requireComplete { throw HistorySnapshotError.truncated }
                    return []
                }
                guard buffer[0..<4] == HistorySnapshotCodec.magic else {
                    throw HistorySnapshotError.malformed
                }
                guard buffer[4] == HistorySnapshotCodec.version else {
                    throw HistorySnapshotError.unknownVersion
                }
                buffer.removeSubrange(0..<5)
                preambleDone = true
            }
            while !sawEnd {
                if buffer.isEmpty {
                    if requireComplete { throw HistorySnapshotError.truncated }
                    break
                }
                let type = buffer[0]
                if type == HistoryRecordType.end {
                    if buffer.count != 1 { throw HistorySnapshotError.malformed }
                    buffer.removeAll()
                    sawEnd = true
                    out.append(.end)
                    break
                }
                if buffer.count < 9 {
                    if requireComplete { throw HistorySnapshotError.truncated }
                    break
                }
                let payloadLen = readUInt64LE(buffer, at: 1)
                if payloadLen > maxRecordBytes {
                    throw HistorySnapshotError.payloadTooLarge
                }
                let total = 9 + Int(payloadLen)
                if buffer.count < total {
                    if requireComplete { throw HistorySnapshotError.truncated }
                    break
                }
                let payload = buffer.subdata(in: 9..<total)
                buffer.removeSubrange(0..<total)
                let record = try decodePayload(type: type, payload: payload)
                try checkOrder(record)
                out.append(record)
            }
            return out
        }

        private mutating func checkOrder(_ record: HistoryRecord) throws {
            if case .skipped = record { return }
            let incoming = record.type
            if incoming == HistoryRecordType.manifest {
                guard case .manifest(let manifest) = record else { return }
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
