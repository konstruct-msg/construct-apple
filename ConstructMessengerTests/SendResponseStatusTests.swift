//
//  SendResponseStatusTests.swift
//  ConstructMessengerTests
//
//  One reading of the server's answer to a send, for the first send, every retry and the session
//  resend (TODO 180).
//

import XCTest
@testable import Construct_Messenger

final class SendResponseStatusTests: XCTestCase {

    private func answer(_ status: String, retryable: Bool = true, errorCode: String = "") -> SendMessageResponse {
        SendMessageResponse(messageId: "m", status: status, retryable: retryable, errorCode: errorCode)
    }

    func testAnAcceptedSendIsSentOrDelivered() {
        XCTAssertEqual(answer("sent").deliveryStatus, .sent)
        XCTAssertEqual(answer("success").deliveryStatus, .sent)
        XCTAssertEqual(answer("delivered").deliveryStatus, .delivered)
        XCTAssertEqual(answer("queued").deliveryStatus, .queued)
    }

    /// A rate limit is a refusal worth repeating. The session resend marked it failed until
    /// 2026-10-20. Mutation: answer `.failed` for any refusal — this reddens.
    func testARateLimitedSendIsQueued() {
        XCTAssertEqual(answer("failed", retryable: true, errorCode: "rateLimit").deliveryStatus, .queued)
    }

    /// Mutation: ignore `retryable` — a blocked or refused send turns queued and is retried forever.
    func testARefusalAfterWhichARetryIsPointlessFails() {
        XCTAssertEqual(answer("blocked", retryable: false, errorCode: "blocked").deliveryStatus, .failed)
        XCTAssertEqual(answer("failed", retryable: false, errorCode: "encryptionFailed").deliveryStatus, .failed)
    }

    func testOnlyARefusedCiphertextNamesTheRatchet() {
        XCTAssertTrue(answer("failed", retryable: false, errorCode: "encryptionFailed").refusedCiphertext)
        XCTAssertFalse(answer("failed", retryable: true, errorCode: "rateLimit").refusedCiphertext)
        XCTAssertFalse(answer("sent").refusedCiphertext)
    }

    func testAnUnknownStatusIsReadAsSentAndFlagged() {
        XCTAssertEqual(answer("weird").deliveryStatus, .sent)
        XCTAssertTrue(answer("weird").isUnknownStatus)
        XCTAssertFalse(answer("sent").isUnknownStatus)
    }

    /// One reading. Mutation: put a `case "delivered":` switch back into any send or session path
    /// — this reddens.
    func testNoSendPathReadsTheStatusStringItself() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var copies: [String] = []
        for dir in ["ConstructMessenger/Services/Messaging", "ConstructMessenger/Services/Session"] {
            let url = root.appendingPathComponent(dir)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where name.hasSuffix(".swift") && name != "SendResponseStatus.swift" {
                let text = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                for (n, line) in text.components(separatedBy: "\n").enumerated()
                where line.contains("case \"delivered\"") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    copies.append("\(name):\(n + 1)")
                }
            }
        }
        XCTAssertEqual(copies, [], "read SendMessageResponse.deliveryStatus")
    }
}
