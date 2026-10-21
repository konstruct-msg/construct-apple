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
        XCTAssertEqual(CallDeviceRouting.onAnswer(from: phone, chosen: ipad, offered: [phone, ipad]), .releaseLate(phone))
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
}
