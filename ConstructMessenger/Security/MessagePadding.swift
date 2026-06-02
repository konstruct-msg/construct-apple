//
//  MessagePadding.swift
//  Construct Messenger
//
//  Ciphertext padding utilities for traffic analysis resistance
//

import Foundation
import Security

enum MessagePadding {
    private static let magic: [UInt8] = [0x4B, 0x50, 0x41, 0x44] // "KPAD"
    private static let headerLength = 8 // 4 bytes magic + 4 bytes length
    private static let buckets = MessagePaddingConfig.buckets

    // MARK: - Data-based API (preferred — no base64 round-trip)

    static func padCiphertext(_ data: Data) -> Data {
        guard MessagePaddingConfig.enabled else { return data }
        let target = targetBucketSize(for: data.count)
        guard let target, target >= data.count + headerLength else { return data }

        var output = Data(capacity: target)
        output.append(contentsOf: magic)
        output.append(contentsOf: UInt32(data.count).bigEndianBytes)
        output.append(data)
        let paddingLength = target - output.count
        if paddingLength > 0 { output.append(randomBytes(count: paddingLength)) }
        return output
    }

    static func unpadCiphertext(_ data: Data) -> Data {
        guard MessagePaddingConfig.enabled, data.count >= headerLength else { return data }
        let prefix = [UInt8](data.prefix(4))
        guard prefix == magic else { return data }
        // `Data.subdata(in:)` takes ABSOLUTE indices. A slice (`bigData[100..<200]`)
        // has startIndex=100, so `subdata(in: 4..<8)` traps. Anchor to startIndex.
        let start = data.startIndex
        let lengthData = data.subdata(in: (start + 4)..<(start + 8))
        let originalLength = lengthData.toUInt32()
        guard originalLength > 0, originalLength <= data.count - headerLength else { return data }
        return data.subdata(in: (start + headerLength)..<(start + headerLength + Int(originalLength)))
    }

    private static func targetBucketSize(for rawLength: Int) -> Int? {
        for bucket in buckets where rawLength + headerLength <= bucket {
            return bucket
        }
        return nil
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return Data(bytes)
        }
        return Data(repeating: 0, count: count)
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ]
    }
}

private extension Data {
    func toUInt32() -> UInt32 {
        let bytes = [UInt8](self)
        guard bytes.count >= 4 else { return 0 }
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }
}
