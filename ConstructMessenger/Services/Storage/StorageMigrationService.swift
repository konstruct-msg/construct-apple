//
//  StorageMigrationService.swift
//  Construct Messenger
//

import Foundation
import CoreData
import Security

/// One-time migration: re-encrypts all `decryptedContent` rows using per-message ChaChaPoly keys,
/// clears the plaintext column, and sets `contentKeyRef` as the migration marker.
///
/// Run once on app launch after Core Data store opens. Safe to call multiple times — rows
/// with `contentKeyRef != nil` are skipped.
@MainActor
final class StorageMigrationService {

    static let shared = StorageMigrationService()

    nonisolated private let batchSize = 100
    private var isMigrating = false

    private init() {}

    func migrateIfNeeded(context: NSManagedObjectContext) {
        guard !isMigrating else { return }
        isMigrating = true
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performMigration(context: context)
            await MainActor.run { self.isMigrating = false }
        }
    }

    private func performMigration(context: NSManagedObjectContext) async {
        let bgContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        bgContext.parent = context
        bgContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        await bgContext.perform {
            self.migrateBatch(in: bgContext)
            self.cleanupLeakedControlRows(in: bgContext)
        }
    }

    /// One-time cleanup of session-control payloads (`session_ready`, `session_ping`,
    /// `binary_init`, …) that leaked into the transcript and were persisted *encrypted at
    /// rest* (`contentKeyRef != nil`, `decryptedContent == nil`). The legacy `migrateBatch`
    /// pass cannot see these — its predicate matches only unencrypted rows — so a delivery
    /// like `session_ready_<UUID>` would render as a bubble forever. We decrypt `displayText`
    /// for already-migrated, regular-typed rows and delete any control artifact.
    /// Guarded by a UserDefaults flag so the (decrypt-per-row) scan runs only once.
    nonisolated private func cleanupLeakedControlRows(in context: NSManagedObjectContext) {
        let flagKey = "storage.controlArtifactCleanup.v1.done"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        let fetchRequest = Message.fetchRequest()
        // Encrypted-at-rest rows that the FRC currently treats as visible (contentTypeRaw == 0).
        fetchRequest.predicate = NSPredicate(format: "contentKeyRef != nil AND contentTypeRaw == 0")
        fetchRequest.fetchBatchSize = batchSize

        guard let messages = try? context.fetch(fetchRequest), !messages.isEmpty else {
            UserDefaults.standard.set(true, forKey: flagKey)
            return
        }

        var deleted = 0
        for message in messages where MessageContentType.isControlPayload(message.displayText) {
            context.delete(message)
            deleted += 1
        }

        if context.hasChanges { try? context.save() }
        UserDefaults.standard.set(true, forKey: flagKey)
        Log.info("Control-artifact cleanup: removed \(deleted) leaked session-control rows", category: "StorageMigration")
    }

    nonisolated private func migrateBatch(in context: NSManagedObjectContext) {
        let fetchRequest = Message.fetchRequest()
        // Only rows that have plaintext and haven't been migrated yet.
        fetchRequest.predicate = NSPredicate(format: "decryptedContent != nil AND contentKeyRef == nil")
        fetchRequest.fetchBatchSize = batchSize

        guard let messages = try? context.fetch(fetchRequest), !messages.isEmpty else {
            Log.info("Storage migration: nothing to migrate", category: "StorageMigration")
            return
        }

        Log.info("Storage migration: migrating \(messages.count) messages…", category: "StorageMigration")

        var migrated = 0
        var deleted = 0

        for message in messages {
            guard let plaintext = message.decryptedContent else { continue }
            let msgId = message.id

            // Infer and fix content type for legacy control messages before clearing content.
            if message.contentTypeRaw == 0 {
                let inferred = MessageContentType.infer(from: plaintext)
                if inferred != .regular {
                    message.contentType = inferred
                }
            }

            // Ephemeral system/control messages have no user value — remove them.
            if message.contentType.isEphemeral {
                context.delete(message)
                deleted += 1
                continue
            }

            // Derive contactId for MessageKeyStore keying (used for bulk-delete by contact).
            let contactId = message.isSentByMe ? message.toUserId : message.fromUserId

            var keyBytes = Data(count: 32)
            let result = keyBytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }
            guard result == errSecSuccess else {
                Log.error("Storage migration: SecRandomCopyBytes failed for \(msgId.prefix(8))…", category: "StorageMigration")
                continue
            }

            guard let plainData = plaintext.data(using: .utf8),
                  let encrypted = try? MessageStorageCrypto.encrypt(plaintext: plainData, key: keyBytes)
            else {
                Log.error("Storage migration: encrypt failed for \(msgId.prefix(8))…", category: "StorageMigration")
                continue
            }

            message.encryptedContent = encrypted
            message.contentKeyRef = msgId
            message.decryptedContent = nil

            // Warm the in-memory cache (best-effort; fine if app is in background).
            MessageKeyStore.shared.store(messageId: msgId, key: keyBytes, contactId: contactId)
            MessageDisplayCache.shared.store(messageId: msgId, plaintext: plaintext)

            migrated += 1

            if migrated % batchSize == 0 {
                try? context.save()
                Log.info("Storage migration: \(migrated) rows done…", category: "StorageMigration")
            }
        }

        if context.hasChanges {
            try? context.save()
        }

        Log.info("Storage migration complete: \(migrated) encrypted, \(deleted) ephemeral removed",
                 category: "StorageMigration")
    }
}
