//
//  OwnDeviceBundleRefusedTests.swift
//  Construct Messenger
//
//  A new device publishes its post-quantum keys after the link. A bundle cached before that is
//  refused by the core, and it stayed cached for up to an hour: on the stand of 2026-11-07 every
//  copy to a just-linked device was refused until the app restarted (todo/276). Real core, real
//  keys.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class OwnDeviceBundleRefusedTests: XCTestCase {
    private var mine: OrchestratorCore!
    private var sibling: OrchestratorCore!
    private var siblingId = ""
    private var coreBefore: OrchestratorCore?
    private let coordinator = MultiDeviceSendCoordinator.shared

    override func setUp() async throws {
        try await super.setUp()
        (mine, _) = try makeTestDevice()
        (sibling, siblingId) = try makeTestDevice()
        coreBefore = CryptoManager.shared.orchestratorCore
        CryptoManager.shared.orchestratorCore = mine
        coordinator.holdOwnDeviceListForTesting()
    }

    override func tearDown() async throws {
        coordinator.invalidateOwnDeviceCache()
        CryptoManager.shared.orchestratorCore = coreBefore
        KeychainManager.shared.deleteSession(for: siblingId)
        try await super.tearDown()
    }

    func testABundleWithItsKeysOpensAndAsksForNothing() async throws {
        var asked = 0

        try await coordinator.openOwnDeviceSession(contactId: siblingId, bundle: try published()) {
            asked += 1
            return nil
        }

        XCTAssertTrue(mine.hasSession(contactId: siblingId))
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(coordinator.ownDeviceListIsCached, "nothing was wrong with the list")
    }

    /// The case from the stand: the keys are there by now, and this copy goes out.
    func testACachedBundleWithoutKeysIsAskedAgainAndTheCopyGoesOut() async throws {
        var asked = 0
        let fresh = try published()

        try await coordinator.openOwnDeviceSession(contactId: siblingId, bundle: try beforePublishing()) {
            asked += 1
            return fresh
        }

        XCTAssertTrue(mine.hasSession(contactId: siblingId))
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(coordinator.ownDeviceListIsCached, "the list that held it is out of date")
    }

    /// The keys are still not there: no session, and the next send asks again, because the list is
    /// gone. One attempt per send, no timer.
    func testKeysStillNotPublishedOpensNothingAndLeavesNoListBehind() async throws {
        var asked = 0
        let stillBare = try beforePublishing()

        await assertRefused {
            try await self.coordinator.openOwnDeviceSession(contactId: self.siblingId, bundle: stillBare) {
                asked += 1
                return stillBare
            }
        }

        XCTAssertFalse(mine.hasSession(contactId: siblingId))
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(coordinator.ownDeviceListIsCached)
    }

    func testAKeyServerWithNoAnswerOpensNothing() async throws {
        let bare = try beforePublishing()

        await assertRefused {
            try await self.coordinator.openOwnDeviceSession(contactId: self.siblingId, bundle: bare) { nil }
        }

        XCTAssertFalse(mine.hasSession(contactId: siblingId))
        XCTAssertFalse(coordinator.ownDeviceListIsCached)
    }

    // MARK: - Helpers

    private func assertRefused(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected the core's refusal")
        } catch SessionError.peerNotPostQuantum {
            // The answer we want.
        } catch {
            XCTFail("expected the core's refusal, got \(error)")
        }
    }

    /// The sibling's bundle as the key server serves it once the device has published everything.
    private func published() throws -> PublicKeyBundleData {
        let b = try sibling.pqxdhTestBundle()
        var data = PublicKeyBundleData(
            userId: "own-account",
            username: "",
            identityPublic: b.identityPublic,
            signedPrekeyPublic: b.signedPrekeyPublic,
            signature: b.signature,
            verifyingKey: b.verifyingKey,
            suiteId: b.suiteId,
            spkUploadedAt: b.spkUploadedAt,
            spkRotationEpoch: b.spkRotationEpoch,
            kyberSpkUploadedAt: b.kyberSpkUploadedAt,
            kyberSpkRotationEpoch: b.kyberSpkRotationEpoch
        )
        data.kyberPreKeyPublic = b.kyberPreKeyPublic
        data.kyberPreKeyId = b.kyberPreKeyId
        data.kyberPreKeyCreatedAt = b.kyberPreKeyCreatedAt
        data.kyberPreKeySignature = b.kyberPreKeySignature
        data.kyberPreKeyHybridSignature = b.kyberPreKeyHybridSignature
        data.hybridIdentityKey = b.hybridIdentityKey
        data.hybridIdentitySignature = b.hybridIdentitySignature
        return data
    }

    /// The same device right after the link: its classic keys and nothing post-quantum yet.
    private func beforePublishing() throws -> PublicKeyBundleData {
        var data = try published()
        data.kyberPreKeyPublic = nil
        data.kyberPreKeyId = nil
        data.kyberPreKeyCreatedAt = nil
        data.kyberPreKeySignature = nil
        data.kyberPreKeyHybridSignature = nil
        data.hybridIdentityKey = nil
        data.hybridIdentitySignature = nil
        data.kyberSpkUploadedAt = 0
        data.kyberSpkRotationEpoch = 0
        return data
    }
}
