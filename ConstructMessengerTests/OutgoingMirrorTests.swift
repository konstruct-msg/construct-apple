//
//  OutgoingMirrorTests.swift
//  ConstructMessengerTests
//
//  Every send that reaches the recipient must tell the other devices about it — ours and theirs.
//
//  ## The defect
//
//  There were two send paths and one of them did half the job. `ChatSendCoordinator` ran
//  SenderSync and fan-out after a successful first attempt; `MessageRetryManager` ran neither. So
//  a message that failed its first send and succeeded on retry reached exactly one device and
//  stayed there — permanently, because nothing retries a mirror — while the sender's UI said sent.
//
//  Measured on a three-device run 2026-08-30 (account ffeeddc6 with an iPhone and a freshly
//  linked Mac, peer 7574fdec): fifteen messages left the peer, `MultiDevice[fanout]` fired twice.
//  The thirteen that went through `sendQueuedMessages` were invisible to the Mac. The session was
//  churning that morning, so almost everything took the retry path, which is why the symptom read
//  as "the desktop received for a while and then stopped".
//
//  Nothing reported it and nothing could. The mirror is best-effort, so its absence and its
//  failure look the same from outside, and a device that never hears of a message has nothing to
//  notice.
//
//  ## What is pinned here
//
//  The halves are no longer callable separately from outside the coordinator. That is the shape
//  of the defect — not "the retry path forgot", but "there were two halves and any caller could
//  take one" — and it is a syntactic question with a syntactic answer.
//

import XCTest
import CoreData
import SwiftProtobuf
@testable import Construct_Messenger

final class OutgoingMirrorTests: XCTestCase {

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")
    }

    /// The only file allowed to call the halves: the one that defines `mirrorOutgoing`.
    private static let coordinator = "MultiDeviceSendCoordinator.swift"

    private func callers(of method: String) throws -> Set<String> {
        var found: Set<String> = []
        let walker = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            guard name != Self.coordinator else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("//"), !t.hasPrefix("///") else { continue }
                if t.contains("\(method)(") { found.insert(name); break }
            }
        }
        return found
    }

    /// Mutation: call `sendSenderSync` directly from `MessageRetryManager` again — this reddens.
    ///
    /// Since 2026-09-22 the mirror has one half — the recipient's devices are reached by the
    /// send itself (`OutboundMessagePipeline.sendToRecipientDevices`), which is why that name is
    /// the second entry here: a send path that calls `sendSenderSync` and the pipeline separately
    /// has re-created the two halves under new names.
    func testNobodyOutsideTheCoordinatorCallsOneHalfOfTheMirror() throws {
        let outside = try callers(of: "sendSenderSync")
        XCTAssertTrue(
            outside.isEmpty,
            """
            \(outside.sorted().joined(separator: ", ")) call sendSenderSync directly.
            A send path must mirror through `mirrorOutgoing` — calling the half is how the retry \
            path came to sync nothing.
            """
        )
        XCTAssertTrue(try callers(of: "fanOutToRecipientDevices").isEmpty,
                      "the fan-out was removed with the primary send; nothing may grow one back")
    }

    /// Every stored resend mirrors, because the resend does it itself.
    ///
    /// Until 2026-11-21 each caller of `resendStored` made its own call, and this test looked for
    /// one call anywhere in the file. The batch retry had it; the single-message retry did not,
    /// and the test stayed green while a message that failed its first send reached the peer on
    /// retry and none of our own devices (Desktop log 2026-11-21). So the call now lives in the
    /// body of `resendStored`, and the assertion reads that body, not the file.
    ///
    /// The assertions name the **call**, not the identifier: the declaration also contains
    /// `mirrorStoredResend(`, and a test that matches it cannot fail.
    ///
    /// Mutation: move the call back out of `resendStored`, or delete it — this reddens.
    func testEveryStoredResendMirrors() throws {
        let retry = sourceRoot.appendingPathComponent("Services/Messaging/MessageRetryManager.swift")
        let text = try String(contentsOf: retry, encoding: .utf8)
        XCTAssertTrue(text.contains("MultiDeviceSendCoordinator.shared.mirrorOutgoing("),
                      "the retry path must mirror — the composer path is not the only way a message is sent")

        let start = try XCTUnwrap(text.range(of: "private func resendStored("), "resendStored is gone")
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n    (private |nonisolated |static |@MainActor|func )", options: .regularExpression)?.lowerBound
            ?? rest.endIndex
        let body = rest[..<end]
        XCTAssertTrue(body.contains("await mirrorStoredResend("),
                      "resendStored must mirror itself — a caller that forgets is how the single retry synced nothing")

        let calls = text.components(separatedBy: "mirrorStoredResend(").count - 1
        XCTAssertEqual(calls, 2, "one declaration and one call, inside resendStored; a second call mirrors twice")
    }
}

/// The plaintext both retry branches rebuild the mirror copy from.
///
/// The stored wire payload cannot serve: it is ciphertext bound to one ratchet, so a copy for
/// another device has to be re-encrypted from the message itself.
final class RecoveredWirePlaintextTests: XCTestCase {

    private func makeMessage(text: String, contentType: MessageContentType = .regular) -> MessageRecord {
        MessageRecord(
            id: UUID().uuidString.lowercased(), chatId: "c", fromUserId: "me", toUserId: "peer",
            isSentByMe: true, timestamp: Date(), orderKey: "k", body: LocalMessagePayload.encodeText(text),
            contentType: contentType, deliveryStatus: .failed, retryCount: 0, suiteId: 4, isEdited: false,
            editedAt: nil, replyToMessageId: nil, replyQuote: nil, transcript: nil,
            transcriptLanguage: nil, transcriptGeneratedAt: nil
        )
    }

    /// The recovered bytes must be the same shape the primary send used — a `MessageContent`
    /// carrying the text — or the recipient's other device reassembles something it cannot read.
    func testTextRoundTripsThroughMessageContent() throws {
        let message = makeMessage(text: "the desktop should see this too")
        let recovered = try XCTUnwrap(MessageRetryManager.recoverWirePlaintext(for: message))
        let content = try Shared_Proto_Messaging_V1_MessageContent(serializedBytes: recovered)
        XCTAssertEqual(content.text.text, "the desktop should see this too")
    }

    /// A reply keeps its quote: the mirror copy is the message, not an approximation of it.
    func testAReplyKeepsItsQuote() throws {
        var message = makeMessage(text: "answering")
        message.replyToMessageId = "8a0c1f6e-0000-0000-0000-000000000001"
        message.replyQuote = "the question"
        let recovered = try XCTUnwrap(MessageRetryManager.recoverWirePlaintext(for: message))
        let content = try Shared_Proto_Messaging_V1_MessageContent(serializedBytes: recovered)
        XCTAssertEqual(content.text.quoted.messageID, "8a0c1f6e-0000-0000-0000-000000000001")
        XCTAssertEqual(content.text.quoted.textPreview, "the question")
    }

    /// A media row rebuilds the album it sent. The composer stores the wire album as the row
    /// (`encodeMediaAlbum(wireContent.mediaAlbum)`), so the copy for another device is the same
    /// `MessageContent` the recipient got. Until 2026-11-21 this returned nil, and a photo that
    /// went out on retry reached none of our own devices (three of the four in that day's log).
    ///
    /// Mutation: return nil for media again, or drop the quote — this reddens.
    func testAMediaRowRebuildsTheAlbumItSent() throws {
        var item = Shared_Proto_Messaging_V1_MediaMessage()
        item.mediaID = "media-1"
        var album = Shared_Proto_Messaging_V1_MediaAlbumMessage()
        album.items = [item]
        album.caption = "caption"
        var quoted = Shared_Proto_Messaging_V1_QuotedMessage()
        quoted.messageID = "8a0c1f6e-0000-0000-0000-000000000002"
        album.quoted = quoted
        var message = makeMessage(text: "", contentType: .media)
        message.body = LocalMessagePayload.encodeMediaAlbum(album)

        let recovered = try XCTUnwrap(MessageRetryManager.recoverWirePlaintext(for: message))
        var sent = Shared_Proto_Messaging_V1_MessageContent()
        sent.mediaAlbum = album
        XCTAssertEqual(try Shared_Proto_Messaging_V1_MessageContent(serializedBytes: recovered), sent)
    }

    /// A media row with nothing to rebuild from — a pre-CTM1 text body, or an album with no
    /// items — is nil, and the caller logs the skip rather than mirroring something wrong.
    func testAMediaRowWithoutAnAlbumIsNotRecoverable() {
        XCTAssertNil(MessageRetryManager.recoverWirePlaintext(for: makeMessage(text: "caption", contentType: .media)))
        var empty = makeMessage(text: "", contentType: .media)
        empty.body = LocalMessagePayload.encodeMediaAlbum(Shared_Proto_Messaging_V1_MediaAlbumMessage())
        XCTAssertNil(MessageRetryManager.recoverWirePlaintext(for: empty))
    }

    /// A control payload that leaked into the transcript must not be mirrored as a message.
    func testAnEmptyRowIsNotRecoverable() {
        XCTAssertNil(MessageRetryManager.recoverWirePlaintext(for: makeMessage(text: "")))
    }
}
