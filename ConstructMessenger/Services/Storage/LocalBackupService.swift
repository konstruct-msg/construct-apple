//
//  LocalBackupService.swift
//  Construct Messenger
//
//  Two use cases share the same binary payload format:
//
//  1. .ctbackup file export/import (BIP39 mnemonic + ChaChaPoly outer encryption)
//       exportBackup()  = buildTransferPayload → ChaChaPoly.seal → write file
//       importBackup()  = read file → ChaChaPoly.open → stageTransferPayload
//
//  2. Direct P2P transfer via NearbyTransferService (channel handles encryption)
//       sender:   buildTransferPayload → NearbyTransferService.startSending()
//       receiver: NearbyTransferService.receivedPayload → stageTransferPayload()
//
//  Payload binary format (unencrypted — 8-byte LE length-prefixed blobs):
//    manifest JSON (UTF-8)
//    Core Data SQLite
//    Core Data SQLite WAL  (length = 0 if absent)
//    MessageKeyStore SQLite
//
//  Key derivation for .ctbackup:
//    seed      = mnemonicToSeed(mnemonic)            // 64-byte BIP39 PBKDF2
//    backupKey = HKDF<SHA256>(seed, salt: "construct_backup_v1")  // 32 bytes
//

import Foundation
import CryptoKit
import CoreData

@MainActor
@Observable
final class LocalBackupService {
    static let shared = LocalBackupService()
    private init() {}

    private static let magic = Data("CTB1".utf8)
    private static let fileVersion: UInt8 = 0x01
    private static let hkdfSalt = Data("construct_backup_v1".utf8)

    nonisolated static let pendingRestoreKey = "ct.pending_restore"
    nonisolated private static let stagingDirName = "ct_restore"

    // MARK: - Mnemonic

    func newMnemonic() throws -> String {
        try generateMnemonic(wordCount: 12)
    }

    // MARK: - Payload Building (shared by export and direct transfer)

    /// Builds the unencrypted binary payload containing all local data.
    /// Used by exportBackup() (which then encrypts it) and by the P2P transfer sender.
    func buildTransferPayload(context: NSManagedObjectContext) async throws -> Data {
        try await context.perform {
            if context.hasChanges { try context.save() }
        }

        let coreSQLURL  = PersistenceController.defaultStoreURL
        let coreWALURL  = URL(fileURLWithPath: coreSQLURL.path + "-wal")
        let keyStoreURL = MessageKeyStore.storageURL

        guard FileManager.default.fileExists(atPath: coreSQLURL.path) else {
            throw BackupError.fileNotFound("ConstructMessenger.sqlite")
        }
        guard FileManager.default.fileExists(atPath: keyStoreURL.path) else {
            throw BackupError.fileNotFound("message_keys.sqlite")
        }

        let coreSQLData  = try Data(contentsOf: coreSQLURL)
        let coreWALData  = FileManager.default.fileExists(atPath: coreWALURL.path)
                           ? (try? Data(contentsOf: coreWALURL)) ?? Data()
                           : Data()
        let keyStoreData = try Data(contentsOf: keyStoreURL)

        let manifest = BackupManifest(
            version: 1,
            createdAt: Int(Date().timeIntervalSince1970),
            coreSQLiteSize: coreSQLData.count,
            keyStoreSQLiteSize: keyStoreData.count
        )
        let manifestData = try JSONEncoder().encode(manifest)

        var payload = Data()
        payload.append(uint64LE(manifestData.count));  payload.append(manifestData)
        payload.append(uint64LE(coreSQLData.count));   payload.append(coreSQLData)
        payload.append(uint64LE(coreWALData.count));   payload.append(coreWALData)
        payload.append(uint64LE(keyStoreData.count));  payload.append(keyStoreData)
        return payload
    }

    /// Parses an unencrypted payload and writes files to the staging directory.
    /// Used by importBackup() (after decryption) and by the P2P transfer receiver.
    /// Sets the pending restore flag — apply takes effect on next app launch.
    func stageTransferPayload(_ data: Data) throws {
        var offset = 0
        let (manifestData, o1) = try readLengthPrefixed(from: data, at: offset); offset = o1
        let (coreSQLData,  o2) = try readLengthPrefixed(from: data, at: offset); offset = o2
        let (coreWALData,  o3) = try readLengthPrefixed(from: data, at: offset); offset = o3
        let (keyStoreData, _)  = try readLengthPrefixed(from: data, at: offset)

        guard (try? JSONDecoder().decode(BackupManifest.self, from: manifestData)) != nil else {
            throw BackupError.invalidFile
        }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stagingDir = appSupport.appendingPathComponent(Self.stagingDirName, isDirectory: true)

        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        try coreSQLData.write(to: stagingDir.appendingPathComponent("ConstructMessenger.sqlite"))
        if !coreWALData.isEmpty {
            try coreWALData.write(to: stagingDir.appendingPathComponent("ConstructMessenger.sqlite-wal"))
        }
        try keyStoreData.write(to: stagingDir.appendingPathComponent("message_keys.sqlite"))

        UserDefaults.standard.set(true, forKey: Self.pendingRestoreKey)
    }

    // MARK: - .ctbackup File Export

    func exportBackup(mnemonic: String, context: NSManagedObjectContext) async throws -> URL {
        let plaintext = try await buildTransferPayload(context: context)
        let key = try deriveKey(from: mnemonic)
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)

        var fileData = Self.magic
        fileData.append(Self.fileVersion)
        fileData.append(sealedBox.combined)

        let timestamp = DateFormatter.backupTimestamp.string(from: Date())
        let filename  = "construct_backup_\(timestamp).ctbackup"
        let tempURL   = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try fileData.write(to: tempURL)
        return tempURL
    }

    // MARK: - .ctbackup File Import

    func importBackup(from fileURL: URL, mnemonic: String) async throws {
        let trimmed = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validateMnemonic(mnemonic: trimmed) else {
            throw BackupError.invalidMnemonic
        }

        let fileData = try Data(contentsOf: fileURL)
        guard fileData.count > 5, fileData.prefix(4) == Self.magic else {
            throw BackupError.invalidFile
        }

        let key = try deriveKey(from: trimmed)

        let sealedBox: ChaChaPoly.SealedBox
        do { sealedBox = try ChaChaPoly.SealedBox(combined: fileData.dropFirst(5)) }
        catch { throw BackupError.invalidFile }

        let plaintext: Data
        do { plaintext = try ChaChaPoly.open(sealedBox, using: key) }
        catch { throw BackupError.decryptionFailed }

        try stageTransferPayload(plaintext)
    }

    // MARK: - Pending Restore (called from PersistenceController before store opens)

    nonisolated static func applyPendingRestoreIfNeeded() {
        guard UserDefaults.standard.bool(forKey: pendingRestoreKey) else { return }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let stagingDir = appSupport.appendingPathComponent(stagingDirName, isDirectory: true)

        let stagedCoreSQL  = stagingDir.appendingPathComponent("ConstructMessenger.sqlite")
        let stagedCoreWAL  = stagingDir.appendingPathComponent("ConstructMessenger.sqlite-wal")
        let stagedKeyStore = stagingDir.appendingPathComponent("message_keys.sqlite")

        guard fm.fileExists(atPath: stagedCoreSQL.path) else {
            UserDefaults.standard.removeObject(forKey: pendingRestoreKey)
            try? fm.removeItem(at: stagingDir)
            return
        }

        do {
            let destCoreSQL  = PersistenceController.defaultStoreURL
            let destCoreWAL  = URL(fileURLWithPath: destCoreSQL.path + "-wal")
            let destCoreSHM  = URL(fileURLWithPath: destCoreSQL.path + "-shm")
            let destKeyStore = MessageKeyStore.storageURL

            for url in [destCoreSQL, destCoreWAL, destCoreSHM] { try? fm.removeItem(at: url) }
            try? fm.removeItem(at: destKeyStore)

            try? fm.createDirectory(
                at: destKeyStore.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try fm.copyItem(at: stagedCoreSQL, to: destCoreSQL)
            if fm.fileExists(atPath: stagedCoreWAL.path) {
                try fm.copyItem(at: stagedCoreWAL, to: destCoreWAL)
            }
            try fm.copyItem(at: stagedKeyStore, to: destKeyStore)

            for url in [destCoreSQL, destCoreWAL, destKeyStore] where fm.fileExists(atPath: url.path) {
                try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            }

            print("✅ LocalBackupService: restore applied successfully")
        } catch {
            print("❌ LocalBackupService: restore failed — \(error)")
        }

        UserDefaults.standard.removeObject(forKey: pendingRestoreKey)
        try? fm.removeItem(at: stagingDir)
    }

    // MARK: - Crypto Helpers

    private func deriveKey(from mnemonic: String) throws -> SymmetricKey {
        let seedBytes = try mnemonicToSeed(mnemonic: mnemonic)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(seedBytes)),
            salt: Self.hkdfSalt,
            info: Data(),
            outputByteCount: 32
        )
    }

    private func uint64LE(_ value: Int) -> Data {
        var le = UInt64(value).littleEndian
        return Data(bytes: &le, count: 8)
    }

    private func readLengthPrefixed(from data: Data, at offset: Int) throws -> (Data, Int) {
        guard offset + 8 <= data.count else { throw BackupError.invalidFile }
        let length = Int(UInt64(littleEndian: data[offset ..< offset + 8].withUnsafeBytes {
            $0.load(as: UInt64.self)
        }))
        let end = offset + 8 + length
        guard end <= data.count else { throw BackupError.invalidFile }
        return (data[offset + 8 ..< end], end)
    }
}

// MARK: - BackupManifest

private struct BackupManifest: Codable {
    let version: Int
    let createdAt: Int
    let coreSQLiteSize: Int
    let keyStoreSQLiteSize: Int
}

// MARK: - BackupError

enum BackupError: LocalizedError {
    case invalidMnemonic
    case fileNotFound(String)
    case invalidFile
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidMnemonic:     return NSLocalizedString("backup_error_invalid_mnemonic", comment: "")
        case .fileNotFound(let n): return "File not found: \(n)"
        case .invalidFile:         return NSLocalizedString("backup_error_invalid_file", comment: "")
        case .decryptionFailed:    return NSLocalizedString("backup_error_invalid_file", comment: "")
        }
    }
}

// MARK: - Helpers

private extension DateFormatter {
    static let backupTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
}
