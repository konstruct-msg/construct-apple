//
//  StuckSendingTests.swift
//  ConstructMessengerTests
//
//  Killing the app between an upload placeholder and the end of the upload left the row at
//  `.sending`. The launch reset then wrote `.queued` for every such row. A placeholder has
//  decrypted content, no wire payload, and content type `.regular`, so the re-encrypt path
//  sent its sentinel JSON to the peer as a text message.
//

import XCTest
@testable import Construct_Messenger

final class StuckSendingTests: XCTestCase {

    func testKilledTextSendIsFailedWithoutSpendingItsRetries() {
        XCTAssertEqual(
            StuckSend.disposition(
                statusIsSending: true,
                ownedByThisProcess: false,
                bodyIsUploadSentinel: false
            ),
            .failForRetry
        )
        XCTAssertEqual(
            StuckSend.write(disposition: .failForRetry, retryCount: 1, retryCeiling: 3),
            StuckSend.Write(status: .failed, retryCount: 1),
            "a real message must stay under the retry ceiling so the existing fetch selects it"
        )
    }

    /// The harm. `.queued` is what the launch reset used to write, and it is the status the
    /// re-encrypt filter selects. A placeholder spends the budget instead.
    func testKilledUploadIsNotRetriedAsText() {
        XCTAssertEqual(
            StuckSend.disposition(
                statusIsSending: true,
                ownedByThisProcess: false,
                bodyIsUploadSentinel: true
            ),
            .retirePlaceholder
        )
        XCTAssertEqual(
            StuckSend.write(disposition: .retirePlaceholder, retryCount: 0, retryCeiling: 3),
            StuckSend.Write(status: .failed, retryCount: 3)
        )
    }

    /// A send this process is still tracking is not an orphan, even when its body is a placeholder.
    func testASendThisProcessStillOwnsIsLeftAlone() {
        XCTAssertEqual(
            StuckSend.disposition(
                statusIsSending: true,
                ownedByThisProcess: true,
                bodyIsUploadSentinel: true
            ),
            .leave
        )
        XCTAssertNil(StuckSend.write(disposition: .leave, retryCount: 0, retryCeiling: 3))
    }

    func testARowThatIsNotSendingIsLeftAlone() {
        XCTAssertEqual(
            StuckSend.disposition(
                statusIsSending: false,
                ownedByThisProcess: false,
                bodyIsUploadSentinel: false
            ),
            .leave
        )
    }

    func testTheUploadSentinelIsNotOrdinaryText() {
        XCTAssertTrue(UploadPlaceholderBody.isSentinel(
            #"{"type":"media","caption":"","media":[{"_placeholder":true}]}"#
        ))
        XCTAssertTrue(UploadPlaceholderBody.isSentinel(
            #"{"type":"media","caption":"album","media":[{"_placeholder":true,"mediaType":"image/jpeg"},{"_placeholder":true,"mediaType":"video/mp4"}]}"#
        ))
        XCTAssertTrue(UploadPlaceholderBody.isSentinel(
            #"{"type":"voice","mediaId":"","mediaUrl":"","mediaKey":"","mediaType":"audio/m4a","size":0,"duration":1.5,"waveform":[0.1],"_uploading":true}"#
        ))
        XCTAssertFalse(
            UploadPlaceholderBody.isSentinel("the flag is {\"_placeholder\":true}, not a message"),
            "a sentence that mentions the flag is still a message"
        )
        XCTAssertFalse(UploadPlaceholderBody.isSentinel(
            #"{"type":"media","caption":"done","media":[{"mediaId":"abc","mediaUrl":"https://example"}]}"#
        ))
        XCTAssertFalse(UploadPlaceholderBody.isSentinel(
            #"{"type":"voice","mediaId":"abc","mediaUrl":"https://example","_uploading":false}"#
        ))
    }
}
