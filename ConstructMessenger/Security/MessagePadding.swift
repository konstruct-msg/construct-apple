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
        let lengthData = data.subdata(in: 4..<8)
        let originalLength = lengthData.toUInt32()
        guard originalLength > 0, originalLength <= data.count - headerLength else { return data }
        return data.subdata(in: headerLength ..< headerLength + Int(originalLength))
    }

    // MARK: - Legacy base64 API (kept for ChatMessage.content String storage paths)

    static func padCiphertextBase64(_ base64: String) -> String {
        guard MessagePaddingConfig.enabled else {
            return base64
        }
        guard let raw = Data(base64Encoded: base64) else {
            return base64
        }

        let target = targetBucketSize(for: raw.count)
        guard let target, target >= raw.count + headerLength else {
            return base64
        }

        var output = Data(capacity: target)
        output.append(contentsOf: magic)
        output.append(contentsOf: UInt32(raw.count).bigEndianBytes)
        output.append(raw)

        let paddingLength = target - output.count
        if paddingLength > 0 {
            output.append(randomBytes(count: paddingLength))
        }

        return output.base64EncodedString()
    }

    static func unpadCiphertextBase64(_ base64: String) -> String {
        guard MessagePaddingConfig.enabled else {
            return base64
        }
        guard let raw = Data(base64Encoded: base64), raw.count >= headerLength else {
            return base64
        }

        let prefix = [UInt8](raw.prefix(4))
        guard prefix == magic else {
            return base64
        }

        let lengthData = raw.subdata(in: 4..<8)
        let originalLength = lengthData.toUInt32()
        guard originalLength > 0, originalLength <= raw.count - headerLength else {
            return base64
        }

        let start = headerLength
        let end = start + Int(originalLength)
        let trimmed = raw.subdata(in: start..<end)
        return trimmed.base64EncodedString()
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
