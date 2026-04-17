//
//  MessageStorageCrypto.swift
//  Construct Messenger
//

import Foundation
import CryptoKit

enum MessageStorageCryptoError: Error {
    case invalidKeyLength
    case invalidCiphertext
}

/// ChaChaPoly-based symmetric encryption for at-rest message content.
/// Key size: 32 bytes. Output format: combined nonce(12) + ciphertext + tag(16).
enum MessageStorageCrypto {

    static func encrypt(plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw MessageStorageCryptoError.invalidKeyLength }
        let symKey = SymmetricKey(data: key)
        let sealed = try ChaChaPoly.seal(plaintext, using: symKey)
        return sealed.combined
    }

    static func decrypt(ciphertext: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw MessageStorageCryptoError.invalidKeyLength }
        guard ciphertext.count > 28 else { throw MessageStorageCryptoError.invalidCiphertext }
        let symKey = SymmetricKey(data: key)
        let sealed = try ChaChaPoly.SealedBox(combined: ciphertext)
        return try ChaChaPoly.open(sealed, using: symKey)
    }
}
