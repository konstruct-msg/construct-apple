//
//  SpeechRecognitionCallbackTests.swift
//  ConstructMessengerTests
//
//  SFSpeechRecognizer calls its handler again after a final result. Resuming the
//  continuation the second time is a runtime trap — the two crashes in the
//  2026-09-23 France log (build 687), signal 5, stack ending in libswiftCore.
//

import XCTest
@testable import Construct_Messenger

final class SpeechRecognitionCallbackTests: XCTestCase {

    /// The crash. Final transcript, then the error the finished task delivers.
    /// Only the first one may resume.
    func testFinalResultThenTheFollowingErrorResumesOnce() {
        var callback = SpeechRecognitionCallback()
        XCTAssertEqual(
            callback.accept(hasError: false, hasResult: true, isFinal: true),
            .success
        )
        XCTAssertEqual(
            callback.accept(hasError: true, hasResult: false, isFinal: false),
            .ignore
        )
    }

    /// The same callback carrying both a final transcript and an error is the
    /// transcript. Treating it as the error drops a result we already have.
    func testFinalResultBeatsAnErrorOnTheSameCallback() {
        var callback = SpeechRecognitionCallback()
        XCTAssertEqual(
            callback.accept(hasError: true, hasResult: true, isFinal: true),
            .success
        )
    }

    /// A partial is not a transcript yet, and it must not settle the callback —
    /// the final result after it still has to resume.
    func testPartialResultDoesNotSettle() {
        var callback = SpeechRecognitionCallback()
        XCTAssertEqual(
            callback.accept(hasError: false, hasResult: true, isFinal: false),
            .ignore
        )
        XCTAssertEqual(
            callback.accept(hasError: false, hasResult: true, isFinal: true),
            .success
        )
    }

    /// An error with no transcript fails the transcription, and a late final
    /// result does not resume again.
    func testErrorThenALateFinalResultResumesOnce() {
        var callback = SpeechRecognitionCallback()
        XCTAssertEqual(
            callback.accept(hasError: true, hasResult: false, isFinal: false),
            .failure
        )
        XCTAssertEqual(
            callback.accept(hasError: false, hasResult: true, isFinal: true),
            .ignore
        )
    }
}
