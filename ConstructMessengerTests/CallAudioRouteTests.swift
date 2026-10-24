//
//  CallAudioRouteTests.swift
//  ConstructMessengerTests
//
//  Which device a Mac call's I/O unit is set to (`CallAudioRouting.swift`). The CoreAudio half
//  runs only on a Mac with the devices plugged in; what can go wrong without one is the choice.
//

import XCTest
@testable import Construct_Messenger

final class CallAudioRouteTests: XCTestCase {
    private let mic = CallAudioRoute.Device(id: 77, uid: "BuiltInMic", name: "Mic", hasInput: true, hasOutput: false)
    private let speakers = CallAudioRoute.Device(id: 70, uid: "BuiltInSpeakers", name: "Speakers", hasInput: false, hasOutput: true)
    private let interface = CallAudioRoute.Device(id: 90, uid: "Interface", name: "Sound card", hasInput: true, hasOutput: true)

    private func plan(input: String?, output: String?, recording: Bool = true) -> CallAudioRoute {
        CallAudioRoute.plan(
            inputUID: input, outputUID: output, recording: recording,
            devices: [mic, speakers, interface], defaultInput: mic.id, defaultOutput: speakers.id
        )
    }

    func testNothingChosenLeavesTheSystemsChoice() {
        XCTAssertEqual(plan(input: nil, output: nil), .system)
        XCTAssertEqual(plan(input: nil, output: nil, recording: false), .system)
    }

    /// The case the owner hit: a sound card for both directions is one device, no aggregate.
    func testOneInterfaceForBothIsUsedDirectly() {
        XCTAssertEqual(plan(input: "Interface", output: "Interface"), .device(interface.id))
    }

    /// Only the output chosen: the microphone stays the system's, so the two are paired.
    func testAChosenOutputIsPairedWithTheDefaultMicrophone() {
        XCTAssertEqual(plan(input: nil, output: "Interface"), .pair(input: mic.id, output: interface.id))
        XCTAssertEqual(plan(input: "Interface", output: nil), .pair(input: interface.id, output: speakers.id))
    }

    /// Before the microphone is on, only the output matters — and an input choice alone changes nothing.
    func testPlayoutOnlyLooksAtTheOutput() {
        XCTAssertEqual(plan(input: nil, output: "Interface", recording: false), .device(interface.id))
        XCTAssertEqual(plan(input: "Interface", output: nil, recording: false), .system)
    }

    /// A device unplugged since it was chosen, or one without that direction, is not a choice.
    func testAMissingOrWrongDirectionDeviceFallsBackToTheSystem() {
        XCTAssertEqual(plan(input: "Gone", output: "Gone"), .system)
        XCTAssertEqual(plan(input: "BuiltInSpeakers", output: "BuiltInMic"), .system)
        XCTAssertEqual(plan(input: "Gone", output: "Interface"), .pair(input: mic.id, output: interface.id))
    }

    func testWithoutASystemDefaultNothingIsForced() {
        let route = CallAudioRoute.plan(
            inputUID: nil, outputUID: "Interface", recording: true,
            devices: [interface], defaultInput: nil, defaultOutput: nil
        )
        XCTAssertEqual(route, .system)
    }
}
