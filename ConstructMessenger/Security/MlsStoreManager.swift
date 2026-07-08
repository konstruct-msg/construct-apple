//
//  MlsStoreManager.swift
//  Construct Messenger
//
//  Owns the device's single long-lived MLS store (Rust `MlsStore` FFI object,
//  see construct-core src/group/mls_store.rs).
//
//  Architecture:
//    - ONE OpenMLS storage per device. KeyPackage private keys live inside the
//      storage that generated them, so a Welcome can only be decrypted by THIS
//      store — never create throwaway instances.
//    - Persistence is a whole-store CFE snapshot (msg_type 0x44) in the Keychain.
//    - The MLS signer is the device's Ed25519 identity signing key from the Rust
//      core; it is passed on construction and is never part of the snapshot.
//
//  Persistence contract: any operation that writes private key material into the
//  store (key package generation, group creation, joining, commits) MUST persist
//  successfully BEFORE its result leaves the device. Publishing a KeyPackage
//  whose private keys were never persisted poisons the server pool: a peer's
//  Welcome built on it can never be decrypted by anyone.
//

import Foundation

enum MlsStoreManagerError: Error {
    /// OrchestratorCore not created yet — the MLS signer keys are unavailable.
    /// Callers must gate on core readiness exactly like the startup OTPK check.
    case coreNotInitialized
    /// Keychain write of the store snapshot failed.
    case persistFailed
}

final class MlsStoreManager {
    static let shared = MlsStoreManager()
    private init() {}

    /// Serializes store access and persist ordering. The Rust wrapper has its
    /// own internal Mutex, but mutate-then-persist must be atomic with respect
    /// to other Swift-side mutations, so the manager holds this lock across both.
    private let lock = NSRecursiveLock()
    private var store: MlsStore?

    // MARK: - Lifecycle

    /// Get-or-create the device store: import the Keychain snapshot if present,
    /// otherwise start fresh. Throws `.coreNotInitialized` before the
    /// OrchestratorCore exists (signer keys come from it).
    func requireStore() throws -> MlsStore {
        lock.lock()
        defer { lock.unlock() }
        if let store { return store }
        let loaded = try loadOrCreate()
        store = loaded
        return loaded
    }

    /// Drop the in-memory store and delete the persisted snapshot.
    /// Destroys membership in every group — only valid during a full key wipe.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        store = nil
        KeychainManager.shared.deleteMlsStore()
        Log.info("MLS store reset (in-memory + Keychain)", category: "MLS")
    }

    private func loadOrCreate() throws -> MlsStore {
        let (signerPrivate, signerPublic) = try signerKeys()
        if let blob = KeychainManager.shared.loadMlsStoreData() {
            do {
                let imported = try importMlsStoreCfe(
                    data: [UInt8](blob),
                    signerPrivateKey: signerPrivate,
                    signerPublicKey: signerPublic
                )
                Log.info("MLS store restored from Keychain (\(blob.count) bytes)", category: "MLS")
                return imported
            } catch {
                // Do NOT recreate over existing state: a fresh store cannot decrypt
                // any group this device is a member of, and silently replacing the
                // blob would make that permanent. Fail the operation instead.
                Log.fault("MLS store import failed — refusing to overwrite existing state: \(error)", category: "MLS")
                throw error
            }
        }
        Log.info("No MLS store in Keychain — creating fresh store", category: "MLS")
        return MlsStore(signerPrivateKey: signerPrivate, signerPublicKey: signerPublic)
    }

    /// Device Ed25519 signing keypair from the Rust core. The MLS BasicCredential
    /// is built over the public (verifying) key.
    private func signerKeys() throws -> (privateKey: [UInt8], publicKey: [UInt8]) {
        let crypto = CryptoManager.shared
        crypto.coreLock.lock()
        defer { crypto.coreLock.unlock() }
        guard let core = crypto.orchestratorCore else {
            throw MlsStoreManagerError.coreNotInitialized
        }
        let privateKey = [UInt8](try core.getSigningKeyBytes())
        let publicKey = try core.getRegistrationBundleFields().verifyingKey
        return (privateKey, publicKey)
    }

    // MARK: - Persistence

    /// Export the full store snapshot and write it to the Keychain.
    /// Throws so callers can refuse to ship results of an unpersisted mutation.
    func persist() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let store else { return }
        let blob = Data(try store.exportCfe())
        guard KeychainManager.shared.saveMlsStore(blob) else {
            Log.error("MLS store persist failed (Keychain write)", category: "MLS")
            throw MlsStoreManagerError.persistFailed
        }
        Log.debug("MLS store persisted (\(blob.count) bytes)", category: "MLS")
    }

    // MARK: - Key packages

    /// Generate `count` KeyPackages and persist the store BEFORE returning them.
    /// Callers may upload the returned wire blobs only after this succeeds.
    func generateKeyPackages(count: Int) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        let store = try requireStore()
        var packages: [Data] = []
        packages.reserveCapacity(count)
        for _ in 0..<count {
            packages.append(Data(try store.generateKeyPackage()))
        }
        try persist()
        return packages
    }
}
