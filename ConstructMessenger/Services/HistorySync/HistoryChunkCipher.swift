//
//  HistoryChunkCipher.swift
//  Construct Messenger
//
//  64 KiB ChaChaPoly chunks. AAD is snapshot_id || user_id || index.
//

import CryptoKit
import Foundation

enum HistoryChunkCipher {
    static let plaintextSize = 65_536
    static let overhead = 28 // 12-byte nonce + 16-byte tag
    static var maxSealedSize: Int { plaintextSize + overhead }

    static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        snapshotId: Data,
        userId: Data,
        index: UInt32
    ) throws -> Data {
        guard plaintext.count <= plaintextSize else { throw HistorySnapshotError.malformed }
        let aad = TransferCrypto.chunkAAD(snapshotId: snapshotId, userId: userId, index: index)
        let nonce = try ChaChaPoly.Nonce(data: nonceBytes(index))
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        return box.combined
    }

    static func open(
        _ combined: Data,
        key: SymmetricKey,
        snapshotId: Data,
        userId: Data,
        index: UInt32
    ) throws -> Data {
        guard combined.count <= maxSealedSize else { throw HistorySnapshotError.malformed }
        let aad = TransferCrypto.chunkAAD(snapshotId: snapshotId, userId: userId, index: index)
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    }

    static func frame(_ sealed: Data) -> Data {
        var out = Data()
        var le = UInt32(sealed.count).littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        out.append(sealed)
        return out
    }

    static var eof: Data {
        Data([0, 0, 0, 0])
    }

    private static func nonceBytes(_ index: UInt32) -> Data {
        var bytes = Data(count: 12)
        var le = index.littleEndian
        withUnsafeBytes(of: &le) { src in
            bytes[0] = src[0]
            bytes[1] = src[1]
            bytes[2] = src[2]
            bytes[3] = src[3]
        }
        return bytes
    }
}
