//
//  CallAudioRouteControlTests.swift
//  ConstructMessengerTests
//
//  The call's audio button is a loudspeaker toggle when the phone has nowhere to send sound but
//  its own earpiece and speaker, and the system route picker when something else is there.
//

#if os(iOS)
import AVFoundation
import XCTest
@testable import Construct_Messenger

final class CallAudioRouteControlTests: XCTestCase {

    func testOnTheEarpieceItIsASpeakerToggleThatIsOff() {
        XCTAssertEqual(
            CallAudioRouteControl.control(outputs: [.builtInReceiver], availableInputs: [.builtInMic]),
            .speakerToggle(isOn: false)
        )
    }

    func testOnTheLoudspeakerTheToggleIsOn() {
        XCTAssertEqual(
            CallAudioRouteControl.control(outputs: [.builtInSpeaker], availableInputs: [.builtInMic]),
            .speakerToggle(isOn: true)
        )
    }

    func testAnAvailableBluetoothHeadsetMakesItThePicker() {
        // Connected but not in use: the earpiece is playing, the choice is still three-way.
        XCTAssertEqual(
            CallAudioRouteControl.control(outputs: [.builtInReceiver], availableInputs: [.builtInMic, .bluetoothHFP]),
            .routePicker
        )
    }

    func testWiredHeadphonesInUseMakeItThePicker() {
        XCTAssertEqual(
            CallAudioRouteControl.control(outputs: [.headphones], availableInputs: [.builtInMic]),
            .routePicker
        )
    }
}
#endif
