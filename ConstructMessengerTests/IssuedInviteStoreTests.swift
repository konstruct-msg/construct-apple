//
//  IssuedInviteStoreTests.swift
//  ConstructMessengerTests
//
//  What any `IssuedInviteStore` must do — `UserDefaults` here; the `LocalStore` implementation runs
//  the same tests by overriding `makeStore()` (the crate's `issued_invites`) — that the acts the
//  journal stored before 2026-10-11 become rows, and that the journal keeps its codes in the seam.
//

import XCTest
@testable import Construct_Messenger

class IssuedInviteStoreTests: XCTestCase {

    private var suites: [String] = []

    private func defaults() -> UserDefaults {
        let name = "invites-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    func makeStore() -> any IssuedInviteStore {
        DefaultsIssuedInviteStore(defaults: defaults())
    }

    override func tearDown() {
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        suites = []
        LocalRepositories.useIssuedInvitesForTesting(nil)
        super.tearDown()
    }

    private func row(_ jti: String, at seconds: TimeInterval, kind: String = IssuedInviteRecord.link, sitting: String? = nil) -> IssuedInviteRecord {
        IssuedInviteRecord(jti: jti, kind: kind, issuedAt: Date(timeIntervalSince1970: seconds), ttlSeconds: 600, sitting: sitting)
    }

    func testARecordAgainReplacesItsRowAndTheListIsNewestFirst() throws {
        let store = makeStore()
        try store.record(row("a", at: 100))
        try store.record(row("b", at: 200))
        try store.record(row("a", at: 300))
        XCTAssertEqual(try store.all().map(\.jti), ["a", "b"])
        XCTAssertEqual(try store.all().first?.issuedAt, Date(timeIntervalSince1970: 300))
    }

    func testCodesAreDeletedByJti() throws {
        let store = makeStore()
        try store.record(row("a", at: 100))
        try store.record(row("b", at: 200))
        try store.record(row("c", at: 300))
        try store.delete(jtis: ["a", "c"])
        XCTAssertEqual(try store.all().map(\.jti), ["b"])
    }

    /// An update keeps every outstanding invite: the acts stored under `invite_journal_v1` come back
    /// as rows — a QR showing's codes under its sitting, a link alone — and the old key is gone.
    ///
    /// Mutation: skip the legacy read — this reddens.
    func testTheJournalWrittenBeforeTheSeamBecomesRows() throws {
        struct Mint: Encodable { let jti: String; let at: Date; let ttl: UInt32? }
        struct Act: Encodable { let id: UUID; let kind: String; let mints: [Mint] }
        let suite = defaults()
        let sitting = UUID()
        let acts = [
            Act(id: UUID(), kind: "link", mints: [Mint(jti: "link-1", at: Date(timeIntervalSince1970: 100), ttl: nil)]),
            Act(id: sitting, kind: "qrSession", mints: [
                Mint(jti: "qr-1", at: Date(timeIntervalSince1970: 200), ttl: 120),
                Mint(jti: "qr-2", at: Date(timeIntervalSince1970: 230), ttl: 120),
            ]),
        ]
        suite.set(try JSONEncoder().encode(acts), forKey: DefaultsIssuedInviteStore.legacyKey)

        let rows = try DefaultsIssuedInviteStore(defaults: suite).all()

        XCTAssertEqual(rows.map(\.jti), ["qr-2", "qr-1", "link-1"])
        XCTAssertEqual(rows.filter { $0.kind == IssuedInviteRecord.qr }.map(\.sitting), [sitting.uuidString, sitting.uuidString])
        let link = try XCTUnwrap(rows.first { $0.jti == "link-1" })
        XCTAssertEqual(link.kind, IssuedInviteRecord.link)
        XCTAssertNil(link.sitting)
        XCTAssertEqual(link.ttlSeconds, UInt32(InviteConfig.ttlSeconds), "a code stored with no life had the global one")
        XCTAssertNil(suite.data(forKey: DefaultsIssuedInviteStore.legacyKey), "moved, not copied")
    }

    /// The app's journal keeps its codes in the seam's store — the path the macOS switch takes — and
    /// a second journal over the same store sees the same acts, grouped as they were issued.
    ///
    /// Mutation: group QR codes by jti instead of sitting — the act count reddens.
    @MainActor
    func testTheJournalKeepsItsCodesInTheSeam() throws {
        let store = makeStore()
        LocalRepositories.useIssuedInvitesForTesting(store)
        let journal = InviteJournal()
        let now = Date()
        journal.recordQRCode(jti: "qr-a", at: now, ttl: 600)
        journal.recordQRCode(jti: "qr-b", at: now.addingTimeInterval(30), ttl: 600)
        journal.closeQRSession()
        journal.recordCopiedLink(jti: UUID().uuidString.lowercased(), at: now.addingTimeInterval(60), ttl: 600)

        XCTAssertEqual(try store.all().count, 3)
        let reopened = InviteJournal(store: store)
        XCTAssertEqual(reopened.live(at: now.addingTimeInterval(90)).map(\.mints.count).sorted(), [1, 2])
    }
}

/// The same cases on the crate's table.
final class LocalStoreIssuedInviteStoreTests: IssuedInviteStoreTests {
    override func makeStore() -> any IssuedInviteStore {
        LocalStoreIssuedInviteStore(session: .inMemoryForTesting())
    }
}
