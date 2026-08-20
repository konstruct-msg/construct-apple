//
//  InviteJournal.swift
//  Construct Messenger
//
//  Created 2026-08-15.
//
//  What this device handed out, kept by the only party that can know it.
//
//  An invite is a capability signed on the device; the server first learns a given `jti`
//  exists when someone redeems it or when the issuer revokes it. `ListInvites` used to
//  exist for this and answered OK with an empty list forever — it could not do otherwise,
//  and it was removed on 2026-08-15 rather than left to be believed
//  (construct-docs backend/INVITE_LIST_REVOKE_SERVER_SPEC.md).
//
//  So the journal is local, and consequently partial: it holds what THIS device issued.
//  On a second device it is empty, and that emptiness is a true statement about this
//  device rather than about the account. Every screen reading it must say so, because
//  "no outstanding invites" and "this device issued none" render identically otherwise.
//

import Foundation

// MARK: - Model

/// One act of issuing, not one capability.
///
/// The distinction is the whole design. A QR sheet left open mints a fresh `jti` every
/// `InviteConfig.qrRotateIntervalSeconds` — 120 an hour — and a journal keyed on
/// capabilities would bury the two links a person deliberately sent to two people under a
/// hundred codes nobody chose. The unit is what the user did: one copied link, or one
/// sitting with the QR on screen.
struct InviteIssuance: Codable, Identifiable, Equatable {

    /// A single minted capability inside the act.
    struct Mint: Codable, Equatable {
        let jti: String
        let at: Date
        /// The life this capability was minted with — v5 states its own, below that the
        /// global maximum applies. Optional so journals written before v5 decode unchanged;
        /// absent means "whatever the global TTL is", which is what those entries had.
        var ttl: UInt32?

        init(jti: String, at: Date, ttl: UInt32? = nil) {
            self.jti = jti
            self.at = at
            self.ttl = ttl
        }

        /// Clamped the same way the server clamps it, so this list and the redeem result
        /// cannot disagree about whether an invite is still good.
        var livesFor: TimeInterval { InviteConfig.effectiveTTL(stated: ttl) }

        func isLive(at now: Date) -> Bool {
            now.timeIntervalSince(at) < livesFor
        }
    }

    enum Kind: String, Codable {
        /// One tap of "copy link" — exactly one capability, handed to one person.
        case link
        /// One sitting with the QR on screen — every rotation while it was open.
        case qrSession
    }

    let id: UUID
    let kind: Kind
    private(set) var mints: [Mint]

    init(id: UUID = UUID(), kind: Kind, mints: [Mint]) {
        self.id = id
        self.kind = kind
        self.mints = mints
    }

    /// When the act began — a QR session is timestamped by the code that opened it, not
    /// by the last rotation, because that is the moment the user remembers.
    var startedAt: Date { mints.first?.at ?? .distantPast }

    /// The act stays live while any of its codes does — so it expires when the last of
    /// them does, which is not the same as the newest one's timestamp once codes can carry
    /// different lives.
    func expiresAt() -> Date {
        mints.map { $0.at.addingTimeInterval($0.livesFor) }.max() ?? .distantPast
    }

    func liveMints(at now: Date) -> [Mint] {
        mints.filter { $0.isLive(at: now) }
    }

    func isLive(at now: Date) -> Bool {
        !liveMints(at: now).isEmpty
    }

    mutating func append(_ mint: Mint) {
        mints.append(mint)
    }

    /// Drop capabilities that outlived their TTL.
    ///
    /// Pruning at mint granularity, not at act granularity, is what bounds a long QR
    /// sitting: at one rotation per 30 s over a 12 h TTL an act tops out around 1440
    /// entries and then holds steady, instead of growing for as long as the sheet is open.
    func pruned(at now: Date) -> InviteIssuance? {
        let live = liveMints(at: now)
        guard !live.isEmpty else { return nil }
        return InviteIssuance(id: id, kind: kind, mints: live)
    }
}

// MARK: - Decisions

/// The branches behind the journal, as pure functions over values.
enum InviteJournalDecision {

    /// Where a new mint belongs.
    ///
    /// A copied link is always its own act: two taps are two links for two people, and
    /// folding them together would restore exactly the ambiguity that
    /// [[InviteShareDecision]] exists to remove. A QR rotation belongs to the sitting that
    /// is open, and only to an open one — a rotation arriving after the sheet closed
    /// starts a new act rather than reviving a finished one.
    enum Placement: Equatable {
        case startNewAct
        case appendToOpenSession
    }

    static func placement(kind: InviteIssuance.Kind, hasOpenQRSession: Bool) -> Placement {
        switch kind {
        case .link:
            return .startNewAct
        case .qrSession:
            return hasOpenQRSession ? .appendToOpenSession : .startNewAct
        }
    }

    /// Everything still redeemable, newest act first.
    ///
    /// Order is by when the act began. Sorting a QR sitting by its last rotation would
    /// float it above links copied after it started, which is not the order the user
    /// performed them in.
    static func live(_ issuances: [InviteIssuance], at now: Date) -> [InviteIssuance] {
        issuances
            .compactMap { $0.pruned(at: now) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - Store

/// Local, per-device record of issued invites.
///
/// Persisted in `UserDefaults`: the contents are random UUIDs and timestamps, never the
/// link itself and never anything about the recipient — the issuer does not learn who
/// redeemed, and this journal does not either. It self-empties one TTL after the last
/// mint, so it is a bounded window rather than a history.
@MainActor
@Observable
final class InviteJournal {

    static let shared = InviteJournal()

    private static let storageKey = "invite_journal_v1"

    private let defaults: UserDefaults
    private(set) var issuances: [InviteIssuance] = []

    /// The QR sitting currently on screen, if any. Nil while no sheet is showing, which is
    /// what makes a rotation after dismissal start a new act rather than extend a closed one.
    private var openQRSessionID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Reading

    func live(at now: Date = Date()) -> [InviteIssuance] {
        InviteJournalDecision.live(issuances, at: now)
    }

    // MARK: Writing

    /// Record a link the user copied. Always its own act.
    func recordCopiedLink(jti: String, at issuedAt: Date = Date(), ttl: UInt32? = nil) {
        record(kind: .link, jti: jti, at: issuedAt, ttl: ttl)
    }

    /// Record a QR code minted while the sheet is open — the first rotation of a sitting
    /// opens the act, the rest join it.
    func recordQRCode(jti: String, at issuedAt: Date = Date(), ttl: UInt32? = nil) {
        record(kind: .qrSession, jti: jti, at: issuedAt, ttl: ttl)
    }

    /// The QR sheet went away. The next code minted starts a new sitting.
    func closeQRSession() {
        openQRSessionID = nil
    }

    /// Drop an act that is no longer outstanding — revoked, or found already redeemed.
    ///
    /// Only ever called with a confirmed answer from the server. Removing on an unconfirmed
    /// attempt would state in the one place the user can check that a live capability is
    /// gone; `InviteRevocationDecision.removesFromJournal` is what guards that.
    /// `openQRSessionID` is deliberately left as it is. Clearing it here looks prudent and
    /// is not: `record` resolves the open sitting by searching for that id among the acts,
    /// so once the act is gone the lookup yields nil and the next code starts a new sitting
    /// on its own. A mutation removing the clear survived every test, which is what a line
    /// with no observable effect looks like.
    func forget(actID: UUID) {
        issuances.removeAll { $0.id == actID }
        save()
    }

    private func record(kind: InviteIssuance.Kind, jti: String, at issuedAt: Date, ttl: UInt32?) {
        let mint = InviteIssuance.Mint(jti: jti, at: issuedAt, ttl: ttl)
        let openIndex = openQRSessionID.flatMap { id in issuances.firstIndex { $0.id == id } }

        switch InviteJournalDecision.placement(kind: kind, hasOpenQRSession: openIndex != nil) {
        case .appendToOpenSession:
            guard let openIndex else { return }
            issuances[openIndex].append(mint)
        case .startNewAct:
            let act = InviteIssuance(kind: kind, mints: [mint])
            issuances.append(act)
            if kind == .qrSession { openQRSessionID = act.id }
        }

        prune()
        save()
    }

    // MARK: Persistence

    private func prune() {
        let now = Date()
        issuances = issuances.compactMap { $0.pruned(at: now) }
        // A pruned-away sitting must not stay "open", or the next rotation would append to
        // an act that is no longer in the list and be silently dropped.
        if let openQRSessionID, !issuances.contains(where: { $0.id == openQRSessionID }) {
            self.openQRSessionID = nil
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            issuances = try JSONDecoder().decode([InviteIssuance].self, from: data)
            prune()
        } catch {
            // A journal that cannot be read is reported, not silently reset to empty: an
            // empty list is the same shape as "nothing outstanding" and would be believed.
            Log.error("InviteJournal: decode failed, starting empty: \(error)", category: "Invite")
            issuances = []
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(issuances), forKey: Self.storageKey)
        } catch {
            Log.error("InviteJournal: encode failed: \(error)", category: "Invite")
        }
    }
}
