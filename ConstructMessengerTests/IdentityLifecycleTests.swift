//
//  IdentityLifecycleTests.swift
//  ConstructMessengerTests
//
//  2026-08-09, build 593. A user's account reset itself, and the account they created to replace
//  it came up holding the previous identity's twelve contacts — visible in the device log two
//  seconds after registration ("subscribed to 12 contacts", "Session prewarm: 9 contact(s) need
//  sessions"). They pruned them by hand, one at a time.
//
//  Two independent defects, one incident:
//
//   1. `KeychainManager.load` collapsed every non-success OSStatus into `nil`, so
//      `errSecInteractionNotAllowed` (device locked, keys intact) read as "never registered" and
//      routed to onboarding. Nothing had to be deleted — `hasRegisteredDeviceKeys = false` is
//      enough to lose an identity.
//   2. Core Data was wiped only by `deleteAccount()`. Registration never cleared it, and
//      `wipeAndReregister()` preserved it on purpose ("Core Data (message history, contacts) is
//      intentionally preserved") — right for seed recovery, which keeps the userId; wrong for
//      "Create New Account", which does not.
//

import XCTest
@testable import Construct_Messenger

final class DeviceKeyAvailabilityTests: XCTestCase {

    private let keyBytes = Data(repeating: 7, count: 32)
    private let idBytes = Data("b26a2cf863f7db482ed0f2963933b86c".utf8)

    // MARK: - The incident

    func testLockedDeviceIsNotAnUnregisteredDevice() {
        // errSecInteractionNotAllowed. Device keys are stored AfterFirstUnlock, so this is the
        // normal state after a reboot until the user unlocks — the keys are right there.
        XCTAssertEqual(
            DeviceKeyAvailability.resolve(
                deviceId: .unreadable(errSecInteractionNotAllowed),
                signingKey: .unreadable(errSecInteractionNotAllowed)
            ),
            .unreadable,
            "reporting this as absent is what sent the user to onboarding and cost them their account"
        )
    }

    func testOneUnreadableReadIsEnoughToRefuseToClaimAbsence() {
        XCTAssertEqual(
            DeviceKeyAvailability.resolve(deviceId: .found(idBytes), signingKey: .unreadable(-25308)),
            .unreadable
        )
        XCTAssertEqual(
            DeviceKeyAvailability.resolve(deviceId: .unreadable(-25308), signingKey: .found(keyBytes)),
            .unreadable
        )
    }

    func testPartialIdentityIsNotAFreshInstall() {
        // One key present, the other genuinely gone. Not a clean device; re-registering over a
        // half-present identity is the worse of the two mistakes.
        XCTAssertEqual(
            DeviceKeyAvailability.resolve(deviceId: .found(idBytes), signingKey: .absent),
            .unreadable
        )
    }

    // MARK: - What must still work

    func testATrulyFreshDeviceStillGoesToRegistration() {
        // The fix must not trap first-time users on a recovery screen.
        XCTAssertEqual(
            DeviceKeyAvailability.resolve(deviceId: .absent, signingKey: .absent),
            .absent
        )
    }

    func testBothKeysPresentIsPresent() {
        XCTAssertEqual(
            DeviceKeyAvailability.resolve(deviceId: .found(idBytes), signingKey: .found(keyBytes)),
            .present
        )
    }

    // MARK: - Classification of raw Keychain status

    func testItemNotFoundIsTheOnlyStatusThatMeansAbsent() {
        XCTAssertEqual(KeychainRead.classify(status: errSecItemNotFound, data: nil), .absent)
        XCTAssertEqual(
            KeychainRead.classify(status: errSecInteractionNotAllowed, data: nil),
            .unreadable(errSecInteractionNotAllowed)
        )
        XCTAssertEqual(KeychainRead.classify(status: -34018, data: nil), .unreadable(-34018))
    }

    func testEmptyPayloadIsUnreadableNotFound() {
        // A zero-byte signing key is not a usable identity, and it is not evidence that the user
        // never registered either.
        XCTAssertEqual(KeychainRead.classify(status: errSecSuccess, data: Data()), .unreadable(errSecSuccess))
    }

    func testSuccessWithBytesIsFound() {
        XCTAssertEqual(KeychainRead.classify(status: errSecSuccess, data: keyBytes), .found(keyBytes))
    }
}

final class LocalStoreOwnershipTests: XCTestCase {

    private let oldOwner = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"   // the identity that was reset
    private let newOwner = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"   // the one that inherited its contacts

    // MARK: - The leak

    func testANewIdentityMayNotHaveThePreviousOnesData() {
        XCTAssertEqual(
            LocalStoreOwnership.disposition(storedOwner: oldOwner, incomingUser: newOwner, storeHasData: true),
            .wipe
        )
    }

    func testUnlabelledDataIsNotHandedToAnyone() {
        // Every install predating the marker is in this state — including the device in the
        // incident, where the store held twelve contacts and no record of whose they were.
        XCTAssertEqual(
            LocalStoreOwnership.disposition(storedOwner: nil, incomingUser: newOwner, storeHasData: true),
            .wipe
        )
        XCTAssertEqual(
            LocalStoreOwnership.disposition(storedOwner: "", incomingUser: newOwner, storeHasData: true),
            .wipe
        )
    }

    // MARK: - What must NOT be wiped

    func testTheOwnerKeepsTheirOwnData() {
        XCTAssertEqual(
            LocalStoreOwnership.disposition(storedOwner: oldOwner, incomingUser: oldOwner, storeHasData: true),
            .keep,
            "seed-phrase recovery keeps the userId — wiping here would be a second bug"
        )
    }

    func testAnEmptyStoreIsNeverWiped() {
        // Nothing to leak, and a wipe would still be a pointless destructive operation.
        XCTAssertEqual(
            LocalStoreOwnership.disposition(storedOwner: nil, incomingUser: newOwner, storeHasData: false),
            .keep
        )
        XCTAssertEqual(
            LocalStoreOwnership.disposition(storedOwner: oldOwner, incomingUser: newOwner, storeHasData: false),
            .keep
        )
    }

    // MARK: - The upgrade path this whole design rests on

    func testClaimingLabelsAnUnownedStore() {
        let defaults = UserDefaults(suiteName: "ownership.claim.\(UUID().uuidString)")!
        XCTAssertTrue(LocalStoreOwnership.claimIfUnowned(oldOwner, defaults: defaults))
        XCTAssertEqual(LocalStoreOwnership.storedOwner(defaults: defaults), oldOwner)
    }

    func testClaimingNeverStealsAnAlreadyOwnedStore() {
        // If this ever returned true for a labelled store, a second identity could quietly
        // relabel someone else's data as its own instead of wiping it.
        let defaults = UserDefaults(suiteName: "ownership.steal.\(UUID().uuidString)")!
        LocalStoreOwnership.claim(oldOwner, defaults: defaults)
        XCTAssertFalse(LocalStoreOwnership.claimIfUnowned(newOwner, defaults: defaults))
        XCTAssertEqual(LocalStoreOwnership.storedOwner(defaults: defaults), oldOwner)
    }

    func testAnUpgradingUserKeepsTheirHistory() {
        // The sequence on first launch of the build that added this: authenticated user, data,
        // no marker. `claimIfUnowned` runs first and the gate then sees its own owner.
        // Without the claim, `disposition` alone would wipe every upgrading user's chats.
        let defaults = UserDefaults(suiteName: "ownership.upgrade.\(UUID().uuidString)")!
        LocalStoreOwnership.claimIfUnowned(oldOwner, defaults: defaults)

        XCTAssertEqual(
            LocalStoreOwnership.disposition(
                storedOwner: LocalStoreOwnership.storedOwner(defaults: defaults),
                incomingUser: oldOwner,
                storeHasData: true
            ),
            .keep
        )
    }
}
