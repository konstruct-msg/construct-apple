//
//  LocalDataWipe.swift
//  Construct Messenger
//
//  Everything this device holds for an account, removed. `decisions/sign-out-wipes-the-device.md`
//

import CoreData
import Foundation

/// The one wipe. Signing out, deleting the account, the duress PIN and this device being removed
/// from another one all end here.
///
/// Until 2026-09-30 there were three wipes with three lists, and each left something: sign-out
/// kept the whole transcript on purpose (so a seed-phrase recovery would find it), and account
/// deletion batch-deleted rows — their bytes stayed in the SQLite free pages and the WAL — while
/// media, thumbnails, stickers, the message-key database and history-transfer files were never
/// touched by any of them.
///
/// **Files are removed by default and kept by exception**, so a store added later is wiped
/// without anyone remembering to list it. The exceptions hold nothing about the account.
///
/// Crypto keys and the session are not here: the callers already delete them, in the order the
/// orchestrator needs (`CryptoManager.deleteAllCryptoKeys` before `KeychainManager`).
@MainActor
enum LocalDataWipe {

    /// Container roots the sweep empties.
    enum Root: CaseIterable {
        case applicationSupport, caches, documents, temporary
    }

    /// What survives a wipe, by root. Downloaded speech-recognition models: public, large, and
    /// nothing in them is the account's. The log directory: `LogCollector` holds the file open and
    /// empties it itself.
    static func survives(_ name: String, in root: Root) -> Bool {
        switch root {
        case .applicationSupport: return name == "whisper-models"
        case .documents: return name == "Logs"
        case .caches, .temporary: return false
        }
    }

    static func run(reason: String) {
        Log.info("LOCAL_WIPE: start reason=\(reason)", category: "Auth")

        // The store key first: whatever the sweep fails to remove is already unreadable.
        LocalStoreKey.destroy()
        // Open handles next: a file removed under an open SQLite handle keeps being written.
        MessageKeyStore.shared.close()
        PersistenceController.shared.replaceStoreWithEmpty { sweepContainer() }

        LogCollector.shared.clearLogs()
        if let logs = directory(.documents)?.appendingPathComponent("Logs", isDirectory: true) {
            try? FileManager.default.removeItem(at: logs.appendingPathComponent("crashes.log"))
        }

        AccountWipeKeys.wipe()
        KeychainManager.shared.deleteAllContactRequestMappings()
        Task { await MediaSendCache.shared.clear() }

        Log.info("LOCAL_WIPE: done reason=\(reason)", category: "Auth")
    }

    // MARK: - Files

    private static func sweepContainer() {
        // A macOS build without the sandbox would resolve these roots to the user's own
        // `~/Library/Application Support` and `~/Documents`, which hold other apps' data.
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil else {
            Log.error("LOCAL_WIPE: not sandboxed — file sweep skipped", category: "Auth")
            return
        }
        #endif
        let fm = FileManager.default
        var removed = 0
        for root in Root.allCases {
            guard let dir = directory(root),
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for entry in entries where !survives(entry.lastPathComponent, in: root) {
                do {
                    try fm.removeItem(at: entry)
                    removed += 1
                } catch {
                    Log.error("LOCAL_WIPE: could not remove \(entry.lastPathComponent): \(error)", category: "Auth")
                }
            }
        }
        Log.info("LOCAL_WIPE: removed \(removed) item(s)", category: "Auth")
    }

    private static func directory(_ root: Root) -> URL? {
        let fm = FileManager.default
        switch root {
        case .applicationSupport: return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        case .caches: return fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        case .documents: return fm.urls(for: .documentDirectory, in: .userDomainMask).first
        case .temporary: return fm.temporaryDirectory
        }
    }
}
