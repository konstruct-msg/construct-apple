//
//  Message+CoreDataClass.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
import Security

@objc(Message)
public class Message: NSManagedObject {

    // MARK: - Display

    /// Decrypted message text, suitable for UI display.
    ///
    /// Resolution order:
    /// 1. In-memory `MessageDisplayCache` (O(1))
    /// 2. Legacy `decryptedContent` field (unmigrated rows)
    /// 3. On-demand decrypt via `MessageKeyStore` + `MessageStorageCrypto`
    var displayText: String {
        MessageDisplayCache.shared.plaintext(for: self)
    }

    /// True if this message has been decrypted — either via legacy `decryptedContent`
    /// or via the encrypted-storage path (`contentKeyRef`).
    var hasDecryptedContent: Bool {
        contentKeyRef != nil || decryptedContent != nil
    }

    /// True if this row is a service/control payload that leaked into the transcript —
    /// e.g. a `{"type":"delivery_receipt",…}` JSON persisted by (or received from) an
    /// older build before delivery receipts were routed by content_type. Such rows must
    /// never render as a chat bubble. Cheap string pre-check gates the JSON parse so
    /// normal messages cost almost nothing.
    var isServiceArtifact: Bool {
        let text = displayText
        guard text.hasPrefix("{"), text.contains("\"delivery_receipt\"") else { return false }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "delivery_receipt"
        else { return false }
        return true
    }

    /// True if this row is an internal session-control signal (`session_ready`,
    /// `session_ping`, `binary_init`, `END_SESSION`, …) that leaked into the transcript.
    /// Such rows must never render as a chat bubble. Because messages are encrypted at
    /// rest (`decryptedContent == nil`), Core Data prefix predicates cannot catch these —
    /// detection runs on the decrypted `displayText`. This is the last-line display guard
    /// backing the persist-time `contentTypeRaw` stamping in `applyStoredEncryption`.
    var isControlArtifact: Bool {
        contentType.isEphemeral || MessageContentType.isControlPayload(displayText)
    }

    // MARK: - Storage Encryption

    /// Encrypt `plaintext` with a fresh random key and persist it in place of the wire bytes.
    ///
    /// - Sets `encryptedContent` to the ChaChaPoly-encrypted blob.
    /// - Sets `contentKeyRef = id` to mark the row as migrated.
    /// - Clears `decryptedContent`.
    /// - Stores the key in `MessageKeyStore` and warms `MessageDisplayCache`.
    ///
    /// Falls back to writing `decryptedContent` if encryption fails (should never happen
    /// on a supported device, but keeps the message visible in any case).
    /// Encrypt UTF-8 text for at-rest storage. Prefer `plaintextData` when the caller
    /// already holds binary (CTM1 envelope / media album).
    func applyStoredEncryption(plaintext: String, contactId: String) {
        applyStoredEncryption(plaintextData: Data(plaintext.utf8), contactId: contactId)
    }

    /// Encrypt opaque local payload bytes (CTM1 envelope or legacy UTF-8) for at-rest storage.
    /// See `LocalMessagePayload` / client/specs/local-message-payload-binary.md (E1/E2).
    func applyStoredEncryption(plaintextData: Data, contactId: String) {
        guard !plaintextData.isEmpty else {
            // encryptedContent must always be non-null (Core Data required attribute).
            encryptedContent = Data()
            decryptedContent = nil
            return
        }
        let msgId = id

        // Stamp content type for FRC filters (control leak guard + media).
        let inferredType = MessageContentType.infer(from: plaintextData)
        if inferredType != .regular { contentType = inferredType }

        var keyBytes = Data(count: 32)
        let status = keyBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess,
              let encrypted = try? MessageStorageCrypto.encrypt(plaintext: plaintextData, key: keyBytes)
        else {
            Log.error("applyStoredEncryption failed for \(msgId.prefix(8))… — falling back to plaintext", category: "Storage")
            encryptedContent = Data()
            // Fallback column is String — only valid for UTF-8 legacy bodies.
            decryptedContent = String(data: plaintextData, encoding: .utf8)
            return
        }

        encryptedContent = encrypted
        contentKeyRef = msgId
        decryptedContent = nil

        MessageKeyStore.shared.storeSync(messageId: msgId, key: keyBytes, contactId: contactId)
        MessageDisplayCache.shared.store(messageId: msgId, plaintextData: plaintextData)
    }
}
