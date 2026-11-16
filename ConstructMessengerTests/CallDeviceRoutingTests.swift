//
//  CallDeviceRoutingTests.swift
//  ConstructMessengerTests
//
//  A call to a person with several devices (`decisions/a-call-rings-every-device.md`): the offer
//  reaches every device we can encrypt for, the first answer takes the call, the others are told
//  it was taken elsewhere, and once a device is chosen nothing from its siblings moves the call.
//  The 2026-10-21 defect this answers: a Mac called, the phone answered to the caller account's
//  pinned device (another phone), and the Mac never heard the answer.
//
//  The rule is the core's since todo 295; these tests run it through this app's bridge, so a
//  wrong wire number or a dropped case in `CallRuleWire` turns them red.
//

import XCTest
@testable import Construct_Messenger

final class CallDeviceRoutingTests: XCTestCase {
    private let mac = "mac", phone = "phone", ipad = "ipad"

    func testBeforeAnyoneAnswersEverySignalGoesToEveryOfferedDevice() {
        XCTAssertEqual(CallDeviceRouting.targets(chosen: nil, offered: [phone, ipad], pinned: phone), [phone, ipad])
    }

    func testOnceADeviceIsChosenOnlyItHearsTheCall() {
        XCTAssertEqual(CallDeviceRouting.targets(chosen: mac, offered: [], pinned: phone), [mac],
                       "the callee answers the device that sent the offer, not the pinned one")
        XCTAssertEqual(CallDeviceRouting.targets(chosen: ipad, offered: [phone, ipad], pinned: phone), [ipad])
    }

    func testWithNeitherTheCallFallsBackToThePinnedDevice() {
        XCTAssertEqual(CallDeviceRouting.targets(chosen: nil, offered: [], pinned: phone), [phone])
        XCTAssertEqual(CallDeviceRouting.targets(chosen: nil, offered: [], pinned: nil), [])
    }

    func testTheOfferGoesToEveryPlannedDeviceWithASessionOnce() {
        let devices = CallDeviceRouting.offerDevices(planned: [phone, ipad, mac, phone],
                                                     hasSession: { $0 != mac }, pinned: phone)
        XCTAssertEqual(devices, [phone, ipad])
    }

    func testWithoutAnySessionTheOfferWaitsOnThePinnedDevice() {
        XCTAssertEqual(CallDeviceRouting.offerDevices(planned: [ipad], hasSession: { _ in false }, pinned: phone), [phone])
    }

    func testOnlyTheChosenDeviceIsHeardOnceChosen() {
        XCTAssertTrue(CallDeviceRouting.admits(phone, chosen: nil))
        XCTAssertTrue(CallDeviceRouting.admits(ipad, chosen: ipad))
        XCTAssertFalse(CallDeviceRouting.admits(phone, chosen: ipad))
    }
}

/// The bridge between this app's call values and the core rule's types.
final class CallRuleWireTests: XCTestCase {
    /// Mutation: any wrong number in the mapping — each proto reason must come back as itself.
    func testEveryHangupReasonCrossesTheBridgeAndBack() {
        let all: [Shared_Proto_Signaling_V1_HangupReason] =
            [.unspecified, .normal, .busy, .declined, .timeout, .connectionFailed, .acceptedElsewhere]
        for r in all {
            XCTAssertEqual(CallRuleWire.proto(CallRuleWire.reason(r)), r, "\(r)")
        }
        XCTAssertEqual(CallRuleWire.reason(.acceptedElsewhere), .acceptedElsewhere)
        XCTAssertEqual(CallRuleWire.reason(.busy), .busy)
    }

    func testAReasonFromANewerPeerReadsAsUnspecified() {
        XCTAssertEqual(CallRuleWire.reason(.UNRECOGNIZED(99)), .unspecified)
    }

    /// Mutations: a server error read as a hangup, a local failure as a hangup, an error code
    /// mapped by name to the wrong number.
    func testHowACallEndedReachesTheRuleAsItHappened() {
        XCTAssertEqual(CallRuleWire.cause(.hangup(.declined)), .hangup(reason: .declined))
        XCTAssertEqual(CallRuleWire.cause(.error(.calleeBusy)), .serverError(error: .calleeBusy))
        XCTAssertEqual(CallRuleWire.cause(.error(.callExpired)), .serverError(error: .callExpired))
        XCTAssertEqual(CallRuleWire.cause(.local("ICE connection failed")), .local)
    }

    /// The screen shows the machine's phase, for the session it belongs to.
    ///
    /// Mutation: any two phases swapped in `CallRuleWire.state`.
    func testTheScreenShowsTheMachinesPhase() {
        let s = CallSession(id: "c1", uuid: UUID(), peerUserId: "p", peerName: "P", direction: .incoming)
        XCTAssertEqual(CallRuleWire.state(.incoming, session: s), .incoming(s))
        XCTAssertEqual(CallRuleWire.state(.dialing, session: s), .dialing(s))
        XCTAssertEqual(CallRuleWire.state(.ringing, session: s), .ringing(s))
        XCTAssertEqual(CallRuleWire.state(.connecting, session: s), .connecting(s))
        XCTAssertEqual(CallRuleWire.state(.active, session: s), .active(s))
    }

    /// How the call ended reaches the machine as it happened: a server's hangup as that hangup, a
    /// server's error as that error (a rate limit ends nothing), our own failure as local.
    ///
    /// Mutations: a hangup ended as a local failure; an error read by the wrong number; a local
    /// failure ended as a hangup.
    func testTheEndReachesTheMachineAsItHappened() {
        func dialled() -> CallMachine {
            let m = CallMachine()
            m.dial(callId: "c1", peerUserId: "p", nowMs: 0)
            return m
        }
        XCTAssertEqual(CallRuleWire.end(.hangup(.timeout), in: dialled(), nowMs: 0)?.outcome, .noAnswer)
        XCTAssertEqual(CallRuleWire.end(.hangup(.busy), in: dialled(), nowMs: 0)?.cause, .hangup(reason: .busy))
        XCTAssertEqual(CallRuleWire.end(.error(.calleeBusy), in: dialled(), nowMs: 0)?.cause,
                       .serverError(error: .calleeBusy))
        XCTAssertEqual(CallRuleWire.end(.error(.callExpired), in: dialled(), nowMs: 0)?.outcome, .noAnswer)
        let limited = dialled()
        XCTAssertNil(CallRuleWire.end(.error(.rateLimited), in: limited, nowMs: 0))
        XCTAssertNotNil(limited.active(), "a rate limit drops one signal and ends nothing")
        XCTAssertEqual(CallRuleWire.end(.local("ICE failed"), in: dialled(), nowMs: 0)?.cause, .local)
        XCTAssertNil(CallRuleWire.end(.local("x"), in: CallMachine(), nowMs: 0))
    }

    /// No devices from the machine means the call's own targets, else the pinned device — never an
    /// empty list, which `sendCallSignalProto` reads as "send to nobody".
    ///
    /// Mutation: pass the empty list through.
    func testAHangupWithNoKnownDeviceFallsBackToThePinnedOne() {
        XCTAssertNil(CallRuleWire.devices([]))
        XCTAssertEqual(CallRuleWire.devices(["d1", "d2"]), ["d1", "d2"])
    }
}
