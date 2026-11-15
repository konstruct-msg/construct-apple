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

    func testTheFirstAnswerTakesTheCallAndReleasesTheOthers() {
        XCTAssertEqual(CallDeviceRouting.onAnswer(from: ipad, chosen: nil, offered: [phone, ipad, mac]),
                       .accept(device: ipad, release: [phone, mac]))
    }

    func testALateAnswerIsReleasedAndDoesNotTakeTheCall() {
        XCTAssertEqual(CallDeviceRouting.onAnswer(from: phone, chosen: ipad, offered: [phone, ipad]), .releaseLate(device: phone))
    }

    func testARepeatedAnswerFromTheChosenDeviceIsTakenAgainWithNothingReleased() {
        XCTAssertEqual(CallDeviceRouting.onAnswer(from: ipad, chosen: ipad, offered: []), .accept(device: ipad, release: []))
    }

    func testOnlyTheChosenDeviceIsHeardOnceChosen() {
        XCTAssertTrue(CallDeviceRouting.admits(phone, chosen: nil))
        XCTAssertTrue(CallDeviceRouting.admits(ipad, chosen: ipad))
        XCTAssertFalse(CallDeviceRouting.admits(phone, chosen: ipad))
    }

    func testADeclineOnAnyDeviceEndsTheCallForAll() {
        XCTAssertEqual(CallDeviceRouting.onHangup(from: phone, reason: .declined, chosen: nil, offered: [phone, ipad]),
                       .end(release: [ipad]))
    }

    func testBusyOnOneDeviceKeepsTheOthersRingingUntilAllAreBusy() {
        XCTAssertEqual(CallDeviceRouting.onHangup(from: phone, reason: .busy, chosen: nil, offered: [phone, ipad]),
                       .dropDevice(remaining: [ipad]))
        XCTAssertEqual(CallDeviceRouting.onHangup(from: ipad, reason: .busy, chosen: nil, offered: [ipad]),
                       .end(release: []))
    }

    func testAHangupFromASiblingOfTheChosenDeviceIsIgnored() {
        XCTAssertEqual(CallDeviceRouting.onHangup(from: phone, reason: .normal, chosen: ipad, offered: [phone, ipad]), .ignore)
        XCTAssertEqual(CallDeviceRouting.onHangup(from: ipad, reason: .normal, chosen: ipad, offered: [phone, ipad]),
                       .end(release: []), "after the answer the others were already released")
    }

    /// Mutation: check `acceptedElsewhere` before `admits` again, or map it to another reason —
    /// the ringing would not stop, or a device we do not hear could stop it.
    func testTakenOnAnotherOfOurDevicesStopsTheRingingAndNothingElse() {
        XCTAssertEqual(CallDeviceRouting.onHangup(from: mac, reason: .acceptedElsewhere, chosen: mac, offered: []),
                       .endTakenElsewhere)
        XCTAssertEqual(CallDeviceRouting.onHangup(from: phone, reason: .acceptedElsewhere, chosen: mac, offered: []),
                       .ignore, "only the call's own device speaks for it")
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

    /// The history row as `endActiveCall` writes it. Mutations: swap the direction, swap two
    /// status codes, write a row for a call taken elsewhere.
    func testTheHistoryRowFollowsTheRule() {
        func row(_ d: CallSession.Direction, _ r: CallEndReason, answered: Bool) -> CallRecord.Status? {
            callHistoryStatus(direction: CallRuleWire.direction(d), cause: CallRuleWire.cause(r), answered: answered)
                .map(CallRuleWire.record)
        }
        XCTAssertEqual(row(.incoming, .hangup(.declined), answered: false), .declined)
        XCTAssertEqual(row(.outgoing, .hangup(.declined), answered: false), .missed)
        XCTAssertEqual(row(.incoming, .hangup(.normal), answered: true), .completed)
        XCTAssertEqual(row(.outgoing, .local("setup"), answered: false), .failed)
        XCTAssertNil(row(.incoming, .hangup(.acceptedElsewhere), answered: false))
    }

    /// The reason `end()` sends: declining while an incoming call still rings, a normal end
    /// otherwise. Mutation: pass the direction the wrong way round.
    func testOurOwnHangupSaysDeclinedOnlyForAnIncomingCallStillRinging() {
        func sent(_ d: CallSession.Direction, ringing: Bool) -> Shared_Proto_Signaling_V1_HangupReason {
            CallRuleWire.proto(callLocalHangupReason(direction: CallRuleWire.direction(d), stillRinging: ringing))
        }
        XCTAssertEqual(sent(.incoming, ringing: true), .declined)
        XCTAssertEqual(sent(.outgoing, ringing: true), .normal)
        XCTAssertEqual(sent(.incoming, ringing: false), .normal)
    }
}
