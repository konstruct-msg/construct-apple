//
//  Message+Transcript.swift
//  Construct Messenger
//
//  Text a row carries beside its body — what was said in a voice message or video note,
//  recognised on this device, and the quote of the message it replies to.
//
//  Both are sealed with the row's storage key — the one `applyStoredEncryption` made for the
//  body — so they are as readable as the body and no more: not by someone reading the database
//  file past the app, and not at all once the row's key is deleted. Until 2026-10-04 both were
//  plaintext columns, `transcriptText` and `replyToContent`, beside a body that was encrypted
//  (vault TODO 115).
//

import Foundation

extension Message {
    /// Opened values, so a bubble re-rendering does not reopen the box each time.
    private static let opened = NSCache<NSString, NSString>()

    var transcript: String? {
        get { sealedText(encryptedTranscript, field: "transcript") ?? transcriptText }
        set {
            transcriptText = nil
            encryptedTranscript = sealing(newValue, field: "transcript")
        }
    }

    /// The reply's quote: a `ReplyPreviewPayload` in its stored form, or nil for no reply.
    var replyQuote: String? {
        get { sealedText(encryptedReplyQuote, field: "quote") ?? replyToContent }
        set {
            replyToContent = nil
            encryptedReplyQuote = sealing(newValue, field: "quote")
        }
    }

    // MARK: Sealing

    private func cacheKey(_ field: String) -> NSString { "\(id)#\(field)" as NSString }

    private func sealedText(_ sealed: Data?, field: String) -> String? {
        guard let sealed, !sealed.isEmpty else { return nil }
        if let hit = Self.opened.object(forKey: cacheKey(field)) { return hit as String }
        guard let key = storageKey,
              let data = try? MessageStorageCrypto.decrypt(ciphertext: sealed, key: key),
              let text = String(data: data, encoding: .utf8) else { return nil }
        Self.opened.setObject(text as NSString, forKey: cacheKey(field))
        return text
    }

    /// `value` sealed with the row's key; nil to clear. No key, no value: keeping it in the clear
    /// is what this replaced. The body goes through `applyStoredEncryption` first, which is what
    /// makes the key.
    private func sealing(_ value: String?, field: String) -> Data? {
        Self.opened.removeObject(forKey: cacheKey(field))
        guard let value, !value.isEmpty else { return nil }
        guard let key = storageKey,
              let sealed = try? MessageStorageCrypto.encrypt(plaintext: Data(value.utf8), key: key) else {
            Log.error("\(field) not stored for \(id.prefix(8))… — the row has no storage key", category: "Storage")
            return nil
        }
        Self.opened.setObject(value as NSString, forKey: cacheKey(field))
        return sealed
    }

    private var storageKey: Data? {
        guard let ref = contentKeyRef else { return nil }
        return MessageKeyStore.shared.fetch(messageId: ref)
    }
}
