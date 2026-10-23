//
//  StudioIsOnTests.swift
//  ConstructMessengerTests
//
//  What the Desktop call window shows for Studio: on only for the call Studio was started on. A
//  call that ends with Studio on clears `active` but not the run's own bookkeeping, and the next
//  call must not open with the Studio button lit.
//

import XCTest
@testable import Construct_Messenger

@MainActor
final class StudioIsOnTests: XCTestCase {

    private let manager = CallManager.shared

    override func setUp() {
        super.setUp()
        LocalRepositories.useCallsForTesting(PersistenceController(inMemory: true).container)
    }

    override func tearDown() {
        manager.studioCallId = nil
        manager.endActiveCall(reason: .local("test"), reportToCallKit: false)
        manager.dismissEndedCall()
        LocalRepositories.useCallsForTesting(nil)
        super.tearDown()
    }

    private func begin(_ id: String) {
        let session = CallSession(id: id, uuid: UUID(), peerUserId: "peer", peerName: "", direction: .outgoing)
        manager.begin(session: session, initialState: .active(session))
    }

    /// Mutation: `studioIsOn` reads only `studioCallId != nil` — the second call opens with Studio
    /// shown on; this reddens.
    func testStudioIsOnOnlyForTheCallItWasStartedOn() {
        begin("first")
        XCTAssertFalse(manager.studioIsOn)

        manager.studioCallId = "first"
        XCTAssertTrue(manager.studioIsOn)

        manager.endActiveCall(reason: .local("test"), reportToCallKit: false)
        XCTAssertFalse(manager.studioIsOn, "no call, no Studio")

        manager.dismissEndedCall()
        begin("second")
        XCTAssertFalse(manager.studioIsOn, "the next call starts without Studio")
    }
}
