//
//  ReactionWire.swift
//  Construct Messenger
//
//  Encode / decode MessageContent.reaction including field 4 timestamp_ms.
//  Generated Swift does not yet have the property (full proto regen wipes
//  Generated/); field 4 is written as a protobuf varint and read back from
//  ReactionMessage.unknownFields. Dual-read: missing field → 0, which the
//  reducer treats as a pre-field peer.
//

import Foundation
import SwiftProtobuf

enum ReactionWire {

    static func encode(_ plan: ReactionReducer.SendPlan) -> Data? {
        var reaction = Shared_Proto_Messaging_V1_ReactionMessage()
        reaction.targetMessageID = plan.targetMessageId
        switch plan.incoming {
        case .add(let emoji):
            reaction.emoji = emoji
            reaction.action = .add
        case .remove:
            reaction.emoji = ""
            reaction.action = .remove
        }
        guard var inner = try? reaction.serializedData() else { return nil }
        if plan.timestampMs > 0 {
            inner.append(int64Field(number: 4, value: plan.timestampMs))
        }
        // MessageContent.reaction = 3, wire type 2 (length-delimited). Generated
        // Swift has no timestampMs, so wrapping via `content.reaction =` would
        // drop field 4. UnknownStorage.append is package-only.
        var outer = Data()
        appendVarint(&outer, (3 << 3) | 2)
        appendVarint(&outer, UInt64(inner.count))
        outer.append(inner)
        return outer
    }

    static func timestampMs(from reaction: Shared_Proto_Messaging_V1_ReactionMessage) -> Int64 {
        int64Field(number: 4, from: reaction.unknownFields.data)
    }

    /// Walk MessageContent bytes for nested ReactionMessage field 4. Used when
    /// the generated decoder skipped the unknown field instead of storing it.
    static func timestampMs(fromMessageContent data: Data) -> Int64 {
        var i = data.startIndex
        while i < data.endIndex {
            guard let key = readVarint(data, at: &i) else { break }
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            if field == 3 && wire == 2 {
                guard let length = readVarint(data, at: &i),
                      data.distance(from: i, to: data.endIndex) >= Int(length)
                else { return 0 }
                let inner = data[i..<data.index(i, offsetBy: Int(length))]
                return int64Field(number: 4, from: Data(inner))
            }
            guard skip(wireType: wire, data: data, at: &i) else { break }
        }
        return 0
    }

    static func actionRawValue(_ incoming: ReactionReducer.Incoming) -> Int {
        switch incoming {
        case .add: return 1
        case .remove: return 2
        }
    }

    static func emoji(_ incoming: ReactionReducer.Incoming) -> String {
        switch incoming {
        case .add(let emoji): return emoji
        case .remove: return ""
        }
    }

    // MARK: - protobuf varint (proto3 int64)

    static func int64Field(number: Int, value: Int64) -> Data {
        var data = Data()
        appendVarint(&data, UInt64(number << 3))
        appendVarint(&data, UInt64(bitPattern: value))
        return data
    }

    static func int64Field(number: Int, from data: Data) -> Int64 {
        var i = data.startIndex
        while i < data.endIndex {
            guard let key = readVarint(data, at: &i) else { break }
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            if field == number && wire == 0 {
                guard let value = readVarint(data, at: &i) else { return 0 }
                return Int64(bitPattern: value)
            }
            guard skip(wireType: wire, data: data, at: &i) else { break }
        }
        return 0
    }

    private static func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v & 0x7F))
    }

    private static func readVarint(_ data: Data, at i: inout Data.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < data.endIndex {
            let byte = data[i]
            i = data.index(after: i)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private static func skip(wireType: Int, data: Data, at i: inout Data.Index) -> Bool {
        switch wireType {
        case 0:
            return readVarint(data, at: &i) != nil
        case 1:
            guard data.distance(from: i, to: data.endIndex) >= 8 else { return false }
            i = data.index(i, offsetBy: 8)
            return true
        case 2:
            guard let length = readVarint(data, at: &i),
                  data.distance(from: i, to: data.endIndex) >= Int(length)
            else { return false }
            i = data.index(i, offsetBy: Int(length))
            return true
        case 5:
            guard data.distance(from: i, to: data.endIndex) >= 4 else { return false }
            i = data.index(i, offsetBy: 4)
            return true
        default:
            return false
        }
    }
}
