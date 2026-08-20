//
//  CryptoCoreTestBootstrap.swift
//  ConstructMessengerTests
//
//  Shared setup for tests that drive the REAL MessageRouter.
//
//  `routeIncomingMessage` returns immediately when the crypto core is absent
//  (`!CryptoManager.shared.isInitialized` → locked-device defer, ccd6ff3a). A suite that skips
//  this bootstrap still goes green while every assertion silently reads zero — that is exactly
//  how SessionQueueWiringTests rotted undetected for five weeks. Centralised here so the next
//  router suite cannot forget it, and so the "did it actually boot?" assertion is unavoidable.
//

import XCTest
import CoreData
@testable import Construct_Messenger

@MainActor
enum CryptoCoreTestBootstrap {

    /// Bring up a real crypto core bound to `localUserId`, or fail the calling test.
    ///
    /// Order matters: `reloadCoreFromKeychain` refuses to build a core until the local user id
    /// is cached, since that id is the Double Ratchet AAD binding.
    static func ensureCore(
        localUserId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if !CryptoManager.shared.isInitialized {
            CryptoManager.shared.setLocalUserId(localUserId)
            _ = try CryptoManager.shared.generateRegistrationBundle()
            CryptoManager.shared.reloadCoreFromKeychain()
        }
        XCTAssertTrue(
            CryptoManager.shared.isInitialized,
            "Crypto core failed to bootstrap — MessageRouter would defer every incoming message "
            + "and every assertion in this suite would vacuously read zero",
            file: file,
            line: line
        )
    }

    /// Fresh in-memory Core Data context — no on-disk state leaks between suites.
    static func inMemoryContext() -> NSManagedObjectContext {
        PersistenceController(inMemory: true).container.viewContext
    }
}
