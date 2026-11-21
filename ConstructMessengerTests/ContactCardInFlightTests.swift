//
//  ContactCardInFlightTests.swift
//  ConstructMessengerTests
//
//  One contact card per device at a time.
//
//  ## The defect
//
//  `sendContactCard` asked which devices are owed, then awaited the address, the seal and the
//  send, and only then recorded the devices as served. Every call arriving inside that window saw
//  the same devices owed. A Desktop catching up on 28 messages from a contact's new device called
//  it once per message: 31 cards to one device in one second (log 2026-11-21), the server's
//  sealed-sender limit for the IP, and the user's own four sends right behind them failed.
//

import XCTest
@testable import Construct_Messenger

final class ContactCardInFlightTests: XCTestCase {

    /// Mutation: let `take` return devices already held — this reddens.
    func testADeviceHeldByOneCallIsNotOwedToTheNext() {
        var flight = DevicesInFlight()
        XCTAssertEqual(flight.take(["a", "b"]), ["a", "b"])
        XCTAssertEqual(flight.take(["b", "c"]), ["c"], "b is being served by the first call")
        XCTAssertEqual(flight.take(["a", "b", "c"]), [])
    }

    /// A device comes back once the call that took it ends, whatever its send did: a failed card
    /// leaves it owed, and the next call must be able to take it.
    ///
    /// Mutation: make `release` a no-op — this reddens.
    func testAReleasedDeviceCanBeTakenAgain() {
        var flight = DevicesInFlight()
        _ = flight.take(["a", "b"])
        flight.release(["a"])
        XCTAssertEqual(flight.take(["a", "b"]), ["a"])
        XCTAssertEqual(flight.held, ["a", "b"])
    }

    /// The guard is taken before `sendContactCard` first suspends, and given back on every exit.
    /// Taken after an `await`, two calls would still both pass the owed check.
    ///
    /// Mutation: compute `owed` without `take`, move it below the first `await`, or drop the
    /// `defer` — this reddens.
    func testSendContactCardHoldsItsDevicesBeforeItSuspends() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger/Services/Messaging/OutboundSessionService.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "func sendContactCard(to contactId: String) async {"))
        let body = text[start.upperBound...]
        let take = try XCTUnwrap(body.range(of: "contactCardsInFlight.take("), "the owed devices are not taken")
        let release = try XCTUnwrap(body.range(of: "defer { contactCardsInFlight.release(owed) }"),
                                    "the taken devices are not given back on every exit")
        let firstAwait = try XCTUnwrap(body.range(of: "await "))
        XCTAssertLessThan(take.lowerBound, firstAwait.lowerBound, "taken after the first suspension")
        XCTAssertLessThan(release.lowerBound, firstAwait.lowerBound, "an exit before the defer keeps the devices")
    }
}
