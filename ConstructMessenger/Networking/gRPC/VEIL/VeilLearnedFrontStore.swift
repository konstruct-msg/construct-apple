//
//  VeilLearnedFrontStore.swift
//  Construct Messenger
//
//  Fronts learned from a *signature* rather than from a *list*.
//
//  Until now the only two anchors that could vouch for a relay address were the cached
//  signed manifest and `VEILConfig.hardcodedRelaySPKIs` (derived from `seedRelays`).
//  Both are public artifacts, so the only way to give a client a front was to publish
//  its coordinates — which on 2026-09-07 published the whole entry-point list in one
//  unauthenticated GET. See construct-docs decisions/veil-front-coordinates-are-not-public.md.
//
//  This store is the replacement anchor: a coordinate tuple that arrived inside a blob
//  signed by `relayConfigSigningKey`, verified, and then pinned **per address**. The
//  binary carries the verification key and nothing else.
//
//  ── The constraint that makes this safe ─────────────────────────────────────────────
//  A learned pin anchors ONE address and nothing else. It must never reach
//  `VeilLocalDiscovery.trustedSPKIs()`: that set is keyed by SPKI with no address, and
//  `accept(spki:trusted:)` asks only for membership. A voucher front's SPKI is public to
//  everyone who photographed the QR, so admitting it there would let a LAN advert claim
//  that identity at any address it likes. `VeilLearnedFrontStoreTests` pins this.
//

import Foundation

// MARK: - Model

/// One front learned from a signature-verified blob.
struct VeilLearnedFront: Codable, Equatable {
    /// `host:port`, lowercased — the exact key `ConnectionLoopRelayBridge.buildRelay`
    /// and `VeilRelayTrust.verify` look up.
    let address: String
    /// TLS SNI to present.
    let sni: String
    /// Lowercase hex SHA-256 SPKI pin (64 chars).
    let spki: String
    /// When this device learned it — newest wins on replacement, oldest is evicted.
    let learnedAt: Date
}

// MARK: - Pure core (unit-tested without a Keychain)

/// Validation and set arithmetic, split out so the rules can be tested directly.
enum VeilLearnedFrontCore {

    /// How many learned fronts to keep. A voucher hands out one front at a time; the
    /// headroom is for signed alternates (§3). Beyond this the oldest is dropped, so a
    /// server that streams alternates cannot grow the Keychain without bound.
    static let maxEntries = 8

    /// Normalise and validate a coordinate tuple, or nil if it is not one.
    ///
    /// Rejecting here rather than at read time matters: `VeilRelayTrust` compares the
    /// stored pin case-insensitively against the offered SPKI, so a malformed or empty
    /// pin that reached the store would be a comparison that cannot fail meaningfully.
    static func normalize(
        address: String,
        sni: String,
        spki: String,
        now: Date = Date()
    ) -> VeilLearnedFront? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pin = spki.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard isValidPin(pin) else { return nil }
        guard let host = hostPortHost(addr) else { return nil }

        var name = sni.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.isEmpty { name = host }
        guard !name.isEmpty else { return nil }

        return VeilLearnedFront(address: addr, sni: name, spki: pin, learnedAt: now)
    }

    /// A pin is exactly 64 lowercase ASCII hex characters (SHA-256 of the SubjectPublicKeyInfo).
    ///
    /// Checked against an explicit ASCII set rather than `Character.isHexDigit`, which
    /// also accepts fullwidth and other Unicode hex forms — those would compare unequal
    /// to a real pin while looking identical in a log line.
    static func isValidPin(_ pin: String) -> Bool {
        let hex = Set("0123456789abcdef")
        return pin.count == 64 && pin.allSatisfy { hex.contains($0) }
    }

    /// The host of a `host:port` address, or nil if it is not one with a usable port.
    /// IPv6 literals arrive bracketed (`[::1]:443`), so the port is taken after the last colon.
    static func hostPortHost(_ address: String) -> String? {
        guard let colon = address.lastIndex(of: ":") else { return nil }
        let host = String(address[address.startIndex..<colon])
        let portText = String(address[address.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else { return nil }
        return host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
    }

    /// Insert `entry`, replacing any existing one for the same address, newest first,
    /// truncated to `limit`.
    static func merge(
        _ existing: [VeilLearnedFront],
        adding entry: VeilLearnedFront,
        limit: Int = maxEntries
    ) -> [VeilLearnedFront] {
        var kept = existing.filter { $0.address != entry.address }
        kept.insert(entry, at: 0)
        kept.sort { $0.learnedAt > $1.learnedAt }
        return Array(kept.prefix(max(1, limit)))
    }
}

// MARK: - Persistence

/// Where the learned set is kept. Injectable so the store's own logic is testable
/// without a Keychain — the codebase's existing preference for VEIL tests.
protocol VeilLearnedFrontPersistence: AnyObject {
    func load() -> Data?
    @discardableResult func save(_ data: Data) -> Bool
    func clear()
}

/// Production backing: one Keychain item holding the whole set.
///
/// `AfterFirstUnlockThisDeviceOnly` for the same reason as `VeilTicketStore` — the veil
/// proxy may start on a push-driven background wake before the user unlocks, and a front
/// without its pin is a front we refuse to dial.
final class VeilLearnedFrontKeychain: VeilLearnedFrontPersistence {
    private static let keychainKey = "veil_learned_fronts"

    func load() -> Data? {
        KeychainManager.shared.loadData(forKey: Self.keychainKey)
    }

    @discardableResult
    func save(_ data: Data) -> Bool {
        KeychainManager.shared.saveData(
            data, forKey: Self.keychainKey,
            accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    func clear() {
        KeychainManager.shared.deleteData(forKey: Self.keychainKey)
    }
}

// MARK: - Store

/// Thread-safe, nonisolated access to the learned fronts.
///
/// Nonisolated and synchronous because the consumers are: `VeilRelayTrust.verify`,
/// `ConnectionLoopRelayBridge.buildRelay` and `VeilRelaySelector.cachedRelayAddresses()`
/// — all called from non-async contexts on arbitrary threads, same as `DiscoveredRelayStore`.
final class VeilLearnedFrontStore: @unchecked Sendable {

    static let shared = VeilLearnedFrontStore(persistence: VeilLearnedFrontKeychain())

    private let lock = NSLock()
    private let persistence: VeilLearnedFrontPersistence
    private var cache: [VeilLearnedFront]?

    /// Non-private so tests can inject in-memory persistence.
    init(persistence: VeilLearnedFrontPersistence) {
        self.persistence = persistence
    }

    // MARK: Reads

    /// The pinned SPKI for `address`, or nil if this device has not learned it.
    func pin(for address: String) -> String? {
        entry(for: address)?.spki
    }

    /// The SNI to present for `address`, or nil if not learned.
    func sni(for address: String) -> String? {
        entry(for: address)?.sni
    }

    func entry(for address: String) -> VeilLearnedFront? {
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lock.withLock { loadLocked().first { $0.address == key } }
    }

    /// All learned `host:port` addresses, newest first.
    func addresses() -> [String] {
        lock.withLock { loadLocked().map(\.address) }
    }

    /// All learned fronts, newest first.
    func all() -> [VeilLearnedFront] {
        lock.withLock { loadLocked() }
    }

    /// The most recently learned front — the one a fresh import means to be used, which
    /// `RelayPool.best()` would not otherwise pick (it prefers fewest failures, and a
    /// seed relay starts at zero).
    func mostRecent() -> VeilLearnedFront? {
        lock.withLock { loadLocked().first }
    }

    // MARK: Writes

    /// Pin a coordinate tuple that has already passed signature verification.
    ///
    /// The caller is the gate: this store records what a verified path decided to trust
    /// and performs no verification of its own beyond well-formedness. Returns false if
    /// the tuple is malformed or persistence failed — callers must treat that as a
    /// refusal to import, never as a reason to dial the address unpinned.
    @discardableResult
    func save(address: String, sni: String, spki: String, now: Date = Date()) -> Bool {
        guard let entry = VeilLearnedFrontCore.normalize(
            address: address, sni: sni, spki: spki, now: now
        ) else {
            Log.error("VEIL learned: refusing malformed coordinates for \(address)", category: "VEIL")
            return false
        }
        return lock.withLock {
            let merged = VeilLearnedFrontCore.merge(loadLocked(), adding: entry)
            guard persistLocked(merged) else {
                Log.error("VEIL learned: failed to persist \(entry.address)", category: "VEIL")
                return false
            }
            Log.info("VEIL learned: pinned front \(entry.address) (\(merged.count) known)", category: "VEIL")
            return true
        }
    }

    @discardableResult
    func remove(_ address: String) -> Bool {
        let key = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lock.withLock {
            let remaining = loadLocked().filter { $0.address != key }
            return persistLocked(remaining)
        }
    }

    /// Forget every learned front (account reset / sign-out).
    func clear() {
        lock.withLock {
            cache = []
            persistence.clear()
        }
    }

    // MARK: Locked helpers

    private func loadLocked() -> [VeilLearnedFront] {
        if let cache { return cache }
        guard let data = persistence.load(),
              let decoded = try? JSONDecoder().decode([VeilLearnedFront].self, from: data) else {
            cache = []
            return []
        }
        let sorted = decoded.sorted { $0.learnedAt > $1.learnedAt }
        cache = sorted
        return sorted
    }

    private func persistLocked(_ entries: [VeilLearnedFront]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        guard persistence.save(data) else { return false }
        cache = entries
        return true
    }
}
