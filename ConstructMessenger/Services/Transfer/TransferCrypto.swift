//
//  TransferCrypto.swift
//  Construct Messenger
//
//  Channel key and chunk AAD for CTT1 v2 / CTHF. Pure.
//

import Foundation
import CryptoKit

enum TransferCrypto {
    enum Salt {
        case nearby
        case file

        var bytes: Data {
            switch self {
            case .nearby: return CTT1V2Layout.channelSalt
            case .file: return CTT1V2Layout.fileSalt
            }
        }
    }

    static func deriveChannelKey(
        ecdh: Data,
        kemSharedSecret: Data,
        salt: Salt,
        snapshotId: Data
    ) -> SymmetricKey {
        var ikm = Data()
        ikm.append(ecdh)
        ikm.append(kemSharedSecret)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt.bytes,
            info: snapshotId,
            outputByteCount: 32
        )
    }

    /// AAD every chunk: snapshot_id || user_id (16 raw) || chunkIndex (UInt32 LE).
    static func chunkAAD(snapshotId: Data, userId: Data, index: UInt32) -> Data {
        var aad = Data()
        aad.append(snapshotId)
        aad.append(userId)
        var le = index.littleEndian
        withUnsafeBytes(of: &le) { aad.append(contentsOf: $0) }
        return aad
    }

    static func discoveryInstanceName(tag: String) -> String {
        HistorySnapshotDisposition.discoveryInstanceName(tag: tag)
    }
}
