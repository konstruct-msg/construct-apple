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

final class CiphertextRefusalTests: XCTestCase {

    private func copy(_ device: String, _ status: String, errorCode: String = "", retryable: Bool = true) -> RecipientSendReport.Copy {
        .init(deviceId: device, response: SendMessageResponse(messageId: "m", status: status, retryable: retryable, errorCode: errorCode), error: nil)
    }

    /// The devices whose copy was refused are the ratchets to retire; an accepted sibling is not.
    func testOnlyTheRefusingDevicesAreNamed() {
        let report = RecipientSendReport(
            copies: [copy("d1", "failed", errorCode: "encryptionFailed", retryable: false), copy("d2", "sent")],
            status: SendMessageResponse(messageId: "m", status: "failed", retryable: false, errorCode: "encryptionFailed"),
            owed: []
        )
        XCTAssertEqual(CiphertextRefusal.refusedDevices(in: report), ["d1"])
    }

    func testARateLimitRetiresNothing() {
        let report = RecipientSendReport(
            copies: [copy("d1", "failed", errorCode: "rateLimit")],
            status: SendMessageResponse(messageId: "m", status: "failed", retryable: true, errorCode: "rateLimit"),
            owed: ["d1"]
        )
        XCTAssertNil(CiphertextRefusal.refusedDevices(in: report))
    }

    /// Every path that sends a stored or re-encrypted copy acts on a refused ciphertext the way the
    /// first send does (TODO 180). Mutation: drop the call from any of these files — this reddens.
    func testEverySendPathRetiresARefusedRatchet() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let expected: [String: Int] = [
            "ConstructMessenger/Services/Messaging/ChatSendCoordinator.swift": 1,
            "ConstructMessenger/Services/Messaging/MessageRetryManager.swift": 3,
            "ConstructMessenger/Services/Session/SessionCoordinator.swift": 1,
        ]
        for (path, count) in expected {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let calls = text.components(separatedBy: "CiphertextRefusal.retireIfRefused(").count - 1
            XCTAssertEqual(calls, count, path)
        }
    }
}
