//
//  SessionScopeTests.swift
//  ConstructMessengerTests
//
//  A session phase is keyed by device, and a peer-wide lock contains the device-wide ones.
//

import XCTest
@testable import Construct_Messenger

final class SessionScopeTests: XCTestCase {

    private let phone   = "6f5e37ac9b1d4e2f8a0c5b7d3e1f9a2c"   // CryptoDeviceId
    private let desktop = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private let account = "14f28d31-2dab-44aa-a123-456789abcdef"  // ServerUserId
    private let other   = "99999999-2dab-44aa-a123-456789abcdef"

    /// The whole point of the re-key: two of one peer's devices are two subjects.
    ///
    /// Under the account key these were one entry, so an init with the phone reported the Desktop
    /// as busy and the Desktop stayed deaf for as long as the phone's init ran.
    func testTwoDevicesOfOnePeerAreDistinctScopes() {
        XCTAssertNotEqual(SessionScope.device(phone), SessionScope.device(desktop))

        var phases: [SessionScope: String] = [:]
        phases[.device(phone)] = "initializing"
        XCTAssertNil(phases[.device(desktop)], "a lock on one device must not read as held on another")
    }

    /// A device id and an account id are different scopes even when the string is the same length
    /// class — the enum is what stops one being read as the other.
    func testDeviceAndPeerScopesNeverCollide() {
        XCTAssertNotEqual(SessionScope.device(account), SessionScope.peer(account))
    }

    // MARK: - Containment

    /// A peer-wide lock covers each device of that account.
    ///
    /// This is what keeps the split safe. The RESPONDER walk locks the whole set because
    /// `plan_receiving_init` has not yet said which device the carrier binds; a prewarm that only
    /// checked its own device key would slip past and race it onto the ratchet the walk opens.
    func testPeerScopeContainsItsDevices() {
        let resolve: (String) -> String? = { [self.phone: self.account, self.desktop: self.account][$0] }

        XCTAssertTrue(SessionScope.peer(account).contains(.device(phone), resolveAccount: resolve))
        XCTAssertTrue(SessionScope.peer(account).contains(.device(desktop), resolveAccount: resolve))
    }

    func testPeerScopeDoesNotContainAnotherAccountsDevice() {
        let resolve: (String) -> String? = { [self.phone: self.other][$0] }
        XCTAssertFalse(SessionScope.peer(account).contains(.device(phone), resolveAccount: resolve))
    }

    /// Containment runs one way. A device-scoped lock must NOT report a peer-wide operation as
    /// already held — that would let one device's heal suppress the walk that reaches the others.
    func testDeviceScopeDoesNotContainThePeer() {
        let resolve: (String) -> String? = { [self.phone: self.account][$0] }
        XCTAssertFalse(SessionScope.device(phone).contains(.peer(account), resolveAccount: resolve))
        XCTAssertFalse(SessionScope.device(phone).contains(.device(desktop), resolveAccount: resolve))
    }

    /// A device attributable to no contact is covered by nothing — the same state as "no session
    /// with them can exist". It must not fall through to "covered by every peer".
    func testUnattributableDeviceIsContainedByNothing() {
        let resolve: (String) -> String? = { _ in nil }
        XCTAssertFalse(SessionScope.peer(account).contains(.device(phone), resolveAccount: resolve))
    }

    func testEveryScopeContainsItself() {
        let resolve: (String) -> String? = { _ in nil }
        XCTAssertTrue(SessionScope.device(phone).contains(.device(phone), resolveAccount: resolve))
        XCTAssertTrue(SessionScope.peer(account).contains(.peer(account), resolveAccount: resolve))
    }

    // MARK: - Storage

    /// The establishment record follows the scope, and hydration reads it back by **device**.
    ///
    /// `hydrateEstablishedTimestampsForRestoredSessions` walks the core's session list, which is
    /// device ids. While the writers keyed this by account, the two never met: every hydrated
    /// lookup answered `nil`, and `isEndSessionStale(nil, …)` is `false`, so the redelivered
    /// teardown the function exists to filter was honoured instead.
    func testStorageKeyIsTheIdentifierInsideTheScope() {
        XCTAssertEqual(SessionScope.device(phone).storageKey, phone)
        XCTAssertEqual(SessionScope.peer(account).storageKey, account)
    }

    func testDeviceIdIsNilForAPeerScope() {
        XCTAssertEqual(SessionScope.device(phone).deviceId, phone)
        XCTAssertNil(SessionScope.peer(account).deviceId)
    }
}
