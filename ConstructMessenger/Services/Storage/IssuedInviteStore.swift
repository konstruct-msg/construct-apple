//
//  IssuedInviteStore.swift
//  Construct Messenger
//
//  The invite capabilities this device minted, behind the storage seam with the operations
//  `LocalStore` has — `record_issued_invite`, `issued_invites`, `delete_issued_invites`
//  (construct-core 0.40.0, `issued_invites`). One row per code; `sitting` groups the codes of one
//  QR showing, and `InviteJournal` builds its acts from that.
//
//  Kinds are the strings Android writes to the same table: "link" and "qr".
//

import Foundation

struct IssuedInviteRecord: Equatable, Codable, Sendable {
    let jti: String
    /// "link" or "qr".
    let kind: String
    let issuedAt: Date
    let ttlSeconds: UInt32
    /// The QR showing this code was minted in; nil for a copied link.
    let sitting: String?

    static let link = "link"
    static let qr = "qr"
}

protocol IssuedInviteStore: Sendable {
    /// Insert, or replace the row of its jti.
    func record(_ invite: IssuedInviteRecord) throws
    /// Newest first.
    func all() throws -> [IssuedInviteRecord]
    func delete(jtis: [String]) throws
}

/// `UserDefaults`, where the journal has always been. Rows under their own key since 2026-10-11;
/// the acts the journal stored before (`invite_journal_v1`) are turned into rows on first read and
/// the old key removed, so an update loses no outstanding invite.
final class DefaultsIssuedInviteStore: IssuedInviteStore, @unchecked Sendable {

    static let storageKey = "construct.issuedInvites.v2"
    static let legacyKey = "invite_journal_v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ invite: IssuedInviteRecord) throws {
        try locked {
            var rows = try load().filter { $0.jti != invite.jti }
            rows.append(invite)
            try save(rows)
        }
    }

    func all() throws -> [IssuedInviteRecord] {
        try locked { try load().sorted { $0.issuedAt > $1.issuedAt } }
    }

    func delete(jtis: [String]) throws {
        let doomed = Set(jtis)
        try locked { try save(load().filter { !doomed.contains($0.jti) }) }
    }

    // MARK: - Storage

    private func load() throws -> [IssuedInviteRecord] {
        if let data = defaults.data(forKey: Self.storageKey) {
            return try JSONDecoder().decode([IssuedInviteRecord].self, from: data)
        }
        guard let legacy = defaults.data(forKey: Self.legacyKey) else { return [] }
        let rows = try Self.rows(fromLegacyActs: legacy)
        try save(rows)
        defaults.removeObject(forKey: Self.legacyKey)
        return rows
    }

    private func save(_ rows: [IssuedInviteRecord]) throws {
        defaults.set(try JSONEncoder().encode(rows), forKey: Self.storageKey)
    }

    /// The journal's acts as it stored them until 2026-10-11, one row per minted code. A code
    /// stored with no life of its own had the global one.
    private static func rows(fromLegacyActs data: Data) throws -> [IssuedInviteRecord] {
        struct Mint: Decodable { let jti: String; let at: Date; let ttl: UInt32? }
        struct Act: Decodable { let id: UUID; let kind: String; let mints: [Mint] }
        return try JSONDecoder().decode([Act].self, from: data).flatMap { act in
            act.mints.map { mint in
                IssuedInviteRecord(
                    jti: mint.jti,
                    kind: act.kind == "qrSession" ? IssuedInviteRecord.qr : IssuedInviteRecord.link,
                    issuedAt: mint.at,
                    ttlSeconds: mint.ttl ?? UInt32(InviteConfig.ttlSeconds),
                    sitting: act.kind == "qrSession" ? act.id.uuidString : nil
                )
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// The crate's `issued_invites`, the table Android writes too. Off until step 4. No journal from
/// before the seam to move: the Desktop never kept one.
final class LocalStoreIssuedInviteStore: IssuedInviteStore, @unchecked Sendable {

    private let store: LocalStore

    init(session: LocalStoreSession) {
        self.store = session.store
    }

    func record(_ invite: IssuedInviteRecord) throws {
        try store.recordIssuedInvite(invite: LocalIssuedInvite(
            jti: invite.jti, kind: invite.kind, issuedAt: invite.issuedAt.unixMs,
            ttlSeconds: invite.ttlSeconds, sitting: invite.sitting
        ))
    }

    func all() throws -> [IssuedInviteRecord] {
        try store.issuedInvites().map {
            IssuedInviteRecord(
                jti: $0.jti, kind: $0.kind, issuedAt: Date(unixMs: $0.issuedAt),
                ttlSeconds: $0.ttlSeconds, sitting: $0.sitting
            )
        }
    }

    func delete(jtis: [String]) throws {
        try store.deleteIssuedInvites(jtis: jtis)
    }
}
