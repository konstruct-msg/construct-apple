//
//  LocalStoreBindingTests.swift
//  ConstructMessengerTests
//
//  `construct-store` as this app links it. SQLCipher is compiled into the core's static library
//  with the ordinary `sqlite3_*` names, next to the system `libsqlite3` Core Data and
//  `MessageKeyStore` use. Were the store's calls to resolve to the system library instead,
//  `PRAGMA key` would be ignored without an error and the store would land on disk in the clear —
//  so this reads the file itself. `decisions/local-store-in-the-core.md`
//

import XCTest
@testable import Construct_Messenger

final class LocalStoreBindingTests: XCTestCase {

    private let key = Data(repeating: 5, count: 32)

    private func contact(_ id: String, name: String) -> LocalContact {
        LocalContact(
            id: id, username: "", displayName: name, localAlias: nil, avatar: nil, publicKey: nil,
            knownIdentityKey: nil, accountAddress: nil, isContact: true, isBlocked: false,
            isSharingWithMe: false, amISharingWith: false, sharedWithMeAt: nil, addedAt: nil,
            ktStatus: 0, hybridCapable: false, securityNotice: 0
        )
    }

    /// Mutation: link the store against the system SQLite — the header and the name appear.
    func testTheStoreFileIsEncryptedInThisApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("construct.db").path

        let store = try LocalStore(path: path, key: key)
        try store.upsertContact(contact: contact("peer", name: "Unmistakable-Name"))

        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: path + "-wal")) { bytes.append(wal) }
        XCTAssertFalse(bytes.starts(with: Data("SQLite format 3".utf8)))
        XCTAssertNil(bytes.range(of: Data("Unmistakable".utf8)))

        XCTAssertThrowsError(try LocalStore(path: path, key: Data(repeating: 6, count: 32))) { error in
            guard case LocalStoreError.WrongKey = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try store.contact(id: "peer")?.displayName, "Unmistakable-Name")

        try store.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The app's own SQLite (`MessageKeyStore`) still works beside it — the two share the
    /// `sqlite3_*` names in one link.
    func testTheAppsOwnSQLiteStillWorks() {
        let messageId = "binding-\(UUID().uuidString)"
        let clear = Data((0..<32).map { UInt8($0) })
        MessageKeyStore.shared.storeSync(messageId: messageId, key: clear, contactId: "c")
        defer { MessageKeyStore.shared.delete(messageId: messageId) }
        XCTAssertEqual(MessageKeyStore.shared.fetch(messageId: messageId), clear)
    }
}
