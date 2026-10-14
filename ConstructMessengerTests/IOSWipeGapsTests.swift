//
//  IOSWipeGapsTests.swift
//  ConstructMessengerTests
//
//  Two things iOS left behind that macOS does not (2026-10-12): the Core Data recovery removed a
//  WAL file name SQLite never writes, and the account-ownership gate emptied Core Data only — the
//  previous identity's invites, owed fan-out copies and partial messages stayed.
//

import XCTest
@testable import Construct_Messenger

final class SQLiteRecoveryFilesTests: XCTestCase {

    /// Mutation: name the sidecars with `appendingPathExtension` again — the WAL and SHM stay and
    /// this reddens.
    func testRecoveryRemovesTheStoreAndItsSidecarsAndNothingElse() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nuke-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for name in ["Store.sqlite", "Store.sqlite-wal", "Store.sqlite-shm", "Other.sqlite"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        PersistenceController.nukeSQLiteFiles(at: dir.appendingPathComponent("Store.sqlite"))

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path), ["Other.sqlite"])
    }
}

@MainActor
final class OwnershipGateServiceRowsTests: XCTestCase {

    private var suites: [String] = []
    private var roots: [URL] = []

    override func setUp() {
        super.setUp()
        LocalRepositories.useIssuedInvitesForTesting(DefaultsIssuedInviteStore(defaults: suite()))
        LocalRepositories.useKeyValueForTesting(DefaultsKeyValueStore(defaults: suite()))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-chunks-\(UUID().uuidString)")
        roots.append(root)
        LocalRepositories.usePendingChunksForTesting(FilePendingChunkStore(root: root))
    }

    override func tearDown() {
        LocalRepositories.useIssuedInvitesForTesting(nil)
        LocalRepositories.useKeyValueForTesting(nil)
        LocalRepositories.usePendingChunksForTesting(nil)
        InviteJournal.shared.reload()
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func suite() -> UserDefaults {
        let name = "gate-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// The gate leaves the next identity none of the last one's service rows.
    ///
    /// Mutations: drop any of the invite delete, `FanoutRetryQueue.removeAll` or
    /// `PendingReassemblyStore.removeAll` from `forgetServiceRows` — its assertion reddens.
    func testTheGateForgetsTheLastIdentitysInvitesQueueAndPartialMessages() throws {
        InviteJournal.shared.reload()
        InviteJournal.shared.recordCopiedLink(jti: UUID().uuidString.lowercased(), at: Date(), ttl: 600)
        FanoutRetryQueue.shared.enqueue(baseMessageId: "m-1", recipientUserId: "account-1", senderUserId: "me", owed: ["device-1"])
        _ = PendingReassemblyStore.shared.put(
            senderId: "alice", messageId: UUID(), chunkIndex: 0, totalChunks: 2,
            plaintextLength: 8, contentType: 1, payload: Data(repeating: 1, count: 4)
        )
        XCTAssertEqual(InviteJournal.shared.live().count, 1, "fixture")
        XCTAssertEqual(FanoutRetryQueue.shared.all().count, 1, "fixture")
        XCTAssertEqual(PendingReassemblyStore.shared.pendingCount(), 1, "fixture")

        AuthViewModel.forgetServiceRows()

        XCTAssertEqual(try LocalRepositories.issuedInvites.all(), [], "the invite rows are gone")
        XCTAssertEqual(InviteJournal.shared.live().count, 0, "and the journal holds none")
        XCTAssertEqual(FanoutRetryQueue.shared.all().count, 0, "no copy is owed for the last identity")
        XCTAssertEqual(PendingReassemblyStore.shared.pendingCount(), 0, "no partial message of the last identity")
    }
}
