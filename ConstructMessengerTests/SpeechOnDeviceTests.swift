//
//  SpeechOnDeviceTests.swift
//  ConstructMessengerTests
//
//  A voice message is decrypted on the device and must be transcribed there. Apple's recognizer
//  sends audio to Apple unless it is told not to and can comply; this pins the rule that the
//  Apple engine is used only when it can run on device. The request itself carries
//  `requiresOnDeviceRecognition = true` (`AppleSpeechProvider`), which only a device run shows.
//

import XCTest
@testable import Construct_Messenger

final class SpeechOnDeviceTests: XCTestCase {
    func testTheAppleEngineIsUsedOnlyWhenItRunsOnTheDevice() throws {
        guard #available(iOS 26, macOS 15, *) else { throw XCTSkip("Apple engine needs iOS 26") }
        XCTAssertTrue(AppleSpeechProvider.mayTranscribe(isAvailable: true, supportsOnDevice: true))
        XCTAssertFalse(AppleSpeechProvider.mayTranscribe(isAvailable: true, supportsOnDevice: false),
                       "available but server-only: the audio would leave the device")
        XCTAssertFalse(AppleSpeechProvider.mayTranscribe(isAvailable: false, supportsOnDevice: true))
    }
}
