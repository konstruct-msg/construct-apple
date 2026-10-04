//
//  Message+Transcript.swift
//  Construct Messenger
//
//  What was said in a voice message or a video note, recognised on this device.
//
//  Sealed with the row's storage key — the one `applyStoredEncryption` made for the body — so
//  it is as readable as the body and no more: not by someone reading the database file past the
//  app, and not at all once the row's key is deleted. Until 2026-10-04 it was a plaintext
//  column, `transcriptText`, beside a body that was encrypted (vault TODO 115).
//

import Foundation

extension Message {
    /// Opened transcripts, so a bubble re-rendering does not reopen the box each time.
    private static let openedTranscripts = NSCache<NSString, NSString>()

    var transcript: String? {
        get {
            guard let sealed = encryptedTranscript, !sealed.isEmpty else {
                // A row from before the launch-time migration has run.
                return transcriptText
            }
            if let opened = Self.openedTranscripts.object(forKey: id as NSString) { return opened as String }
            guard let key = storageKey,
                  let data = try? MessageStorageCrypto.decrypt(ciphertext: sealed, key: key),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            Self.openedTranscripts.setObject(text as NSString, forKey: id as NSString)
            return text
        }
        set {
            transcriptText = nil
            Self.openedTranscripts.removeObject(forKey: id as NSString)
            guard let newValue, !newValue.isEmpty else {
                encryptedTranscript = nil
                return
            }
            // No key, no transcript: storing it in the clear is what this replaced. The row's
            // body goes through `applyStoredEncryption` first, which is what makes the key.
            guard let key = storageKey,
                  let sealed = try? MessageStorageCrypto.encrypt(plaintext: Data(newValue.utf8), key: key) else {
                Log.error("Transcript not stored for \(id.prefix(8))… — the row has no storage key", category: "Storage")
                encryptedTranscript = nil
                return
            }
            encryptedTranscript = sealed
            Self.openedTranscripts.setObject(newValue as NSString, forKey: id as NSString)
        }
    }

    private var storageKey: Data? {
        guard let ref = contentKeyRef else { return nil }
        return MessageKeyStore.shared.fetch(messageId: ref)
    }
}
