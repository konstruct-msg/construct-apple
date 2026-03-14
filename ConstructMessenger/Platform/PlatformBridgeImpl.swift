//
//  PlatformBridgeImpl.swift
//  Construct Messenger
//
//  Swift implementation of the UniFFI `PlatformBridge` callback interface.
//  The Rust `OrchestratorCore` holds a reference to this and calls through it
//  for all platform I/O: Keychain secrets, structured record storage, and logging.
//
//  Contract (mirrors Rust `platform_bridge.rs`):
//  - saveToSecureStore / loadFromSecureStore → iOS Keychain
//  - persistRecord / queryRecord             → UserDefaults (snapshot per table)
//  - logEvent                                → os_log via Log utility
//

import Foundation

/// Concrete Swift implementation of the Rust `PlatformBridge` callback interface.
///
/// Routing:
/// - Keychain: `KeychainManager.shared` (data keyed as-is)
/// - Record store: `UserDefaults` under `"rust_record.\(table)"` (one snapshot per table)
/// - Logging: `Log` utility (maps level string → appropriate log call)
final class PlatformBridgeImpl: PlatformBridge {

    static let shared = PlatformBridgeImpl()
    private init() {}

    // MARK: - Secure store (Keychain)

    func saveToSecureStore(key: String, data: Data) {
        let ok = KeychainManager.shared.saveData(data, forKey: key)
        if !ok {
            Log.error("❌ PlatformBridge: failed to save '\(key)' to Keychain", category: "PlatformBridge")
        }
    }

    func loadFromSecureStore(key: String) -> Data? {
        return KeychainManager.shared.loadData(forKey: key)
    }

    // MARK: - Record store (UserDefaults snapshot per table)
    //
    // Semantics mirror the Rust MockPlatformBridge: query_record returns the
    // most-recently persisted record for the given table. query_json is ignored
    // (as in the Rust mock) — the callers use single-record tables for snapshots.

    private static let udPrefix = "rust_record."

    func persistRecord(table: String, json: String) {
        UserDefaults.standard.set(json, forKey: Self.udPrefix + table)
        Log.debug("💾 PlatformBridge: persisted record in '\(table)'", category: "PlatformBridge")
    }

    func queryRecord(table: String, queryJson: String) -> String? {
        return UserDefaults.standard.string(forKey: Self.udPrefix + table)
    }

    // MARK: - Logging

    func logEvent(level: String, tag: String, message: String) {
        let formatted = "[\(tag)] \(message)"
        switch level {
        case "debug":  Log.debug(formatted, category: "RustCore")
        case "info":   Log.info(formatted, category: "RustCore")
        case "warn":   Log.error(formatted, category: "RustCore")
        case "error":  Log.error(formatted, category: "RustCore")
        default:       Log.debug(formatted, category: "RustCore")
        }
    }
}
