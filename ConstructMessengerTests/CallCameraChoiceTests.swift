//
//  CallCameraChoiceTests.swift
//  ConstructMessengerTests
//
//  A phone picks its camera by position. A Mac's cameras mostly have none (built-in, USB,
//  Continuity Camera report `unspecified`), so a Mac asked for "front" by position found no
//  camera at all. Desktop video calls (2026-10-29) take the system's default camera instead.
//

import XCTest
@testable import Construct_Messenger

final class CallCameraChoiceTests: XCTestCase {

    /// A phone: front and back by position, never any other.
    func testAPhonePicksByPosition() {
        let positions: [CallCameraChoice.Position] = [.back, .front]
        XCTAssertEqual(CallCameraChoice.device(positions: positions, facing: .front, defaultIndex: nil, anyPosition: false), 1)
        XCTAssertEqual(CallCameraChoice.device(positions: positions, facing: .back, defaultIndex: nil, anyPosition: false), 0)
        XCTAssertNil(CallCameraChoice.device(positions: [.unspecified], facing: .front, defaultIndex: 0, anyPosition: false))
    }

    /// A Mac with unpositioned cameras takes the system default, else the first.
    /// Mutation: drop the `anyPosition` fallback (return nil) — this reddens.
    func testAMacTakesTheDefaultCamera() {
        let positions: [CallCameraChoice.Position] = [.unspecified, .unspecified]
        XCTAssertEqual(CallCameraChoice.device(positions: positions, facing: .front, defaultIndex: 1, anyPosition: true), 1)
        XCTAssertEqual(CallCameraChoice.device(positions: positions, facing: .front, defaultIndex: nil, anyPosition: true), 0)
        XCTAssertNil(CallCameraChoice.device(positions: [], facing: .front, defaultIndex: nil, anyPosition: true))
    }

    /// A Mac camera that does say "front" is still preferred over the default.
    func testAPositionedCameraWinsOnAMacToo() {
        let positions: [CallCameraChoice.Position] = [.unspecified, .front]
        XCTAssertEqual(CallCameraChoice.device(positions: positions, facing: .front, defaultIndex: 0, anyPosition: true), 1)
    }
}
