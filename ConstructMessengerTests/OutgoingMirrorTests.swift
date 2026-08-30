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
    func testNobodyOutsideTheCoordinatorCallsOneHalfOfTheMirror() throws {
        for half in ["sendSenderSync", "fanOutToRecipientDevices"] {
            let outside = try callers(of: half)
            XCTAssertTrue(
                outside.isEmpty,
                """
                \(outside.sorted().joined(separator: ", ")) call \(half) directly.
                A send path must mirror through `mirrorOutgoing`, which does both halves — \
                calling one is how the retry path came to sync nothing and fan out nothing.
                """
            )
        }
    }

    /// Both retry branches have to call it, or the defect is back with the calls merely renamed.
    ///
    /// The assertions name the **call**, not the identifier. The first draft looked for
    /// `mirrorStoredResend(` anywhere in the file and passed against a build where the call was
    /// deleted — the function's own declaration contains that text. A source test that matches a
    /// definition when it means a call is a test that cannot fail for the thing it is about.
    ///
    /// Mutation: delete either call from MessageRetryManager — this reddens.
    func testBothRetryBranchesMirror() throws {
        let retry = sourceRoot.appendingPathComponent("Services/Messaging/MessageRetryManager.swift")
        let text = try String(contentsOf: retry, encoding: .utf8)
        XCTAssertTrue(text.contains("MultiDeviceSendCoordinator.shared.mirrorOutgoing("),
                      "the retry path must mirror — the composer path is not the only way a message is sent")
        XCTAssertTrue(text.contains("await self.mirrorStoredResend("),
                      "the stored-ciphertext resend is a second retry branch and needs the mirror too")
    }
}

/// The plaintext both retry branches rebuild the mirror copy from.
///
/// The stored wire payload cannot serve: it is ciphertext bound to one ratchet, so a copy for
/// another device has to be re-encrypted from the message itself.
@MainActor
final class RecoveredWirePlaintextTests: XCTestCase {

    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        context = PersistenceController(inMemory: true).container.viewContext
    }

    override func tearDown() {
        context = nil
        super.tearDown()
    }

    private func makeMessage(text: String, contentType: MessageContentType = .regular) -> Construct_Messenger.Message {
        let message = Construct_Messenger.Message(context: context)
        message.id = UUID().uuidString
        message.timestamp = Date()
        message.decryptedContent = text
        message.contentTypeRaw = contentType.rawValue
        return message
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
        let message = makeMessage(text: "answering")
        message.replyToMessageId = "8a0c1f6e-0000-0000-0000-000000000001"
        message.replyToContent = "the question"
        let recovered = try XCTUnwrap(MessageRetryManager.recoverWirePlaintext(for: message))
        let content = try Shared_Proto_Messaging_V1_MessageContent(serializedBytes: recovered)
        XCTAssertEqual(content.text.quoted.messageID, "8a0c1f6e-0000-0000-0000-000000000001")
        XCTAssertEqual(content.text.quoted.textPreview, "the question")
    }

    /// Media is the one case that cannot be rebuilt — its wire plaintext is a binary album proto
    /// the persisted model does not hold. `nil` is the honest answer, and the caller logs the skip
    /// rather than mirroring something wrong.
    func testMediaCannotBeRecovered() {
        XCTAssertNil(MessageRetryManager.recoverWirePlaintext(for: makeMessage(text: "caption", contentType: .media)))
    }

    /// A control payload that leaked into the transcript must not be mirrored as a message.
    func testAnEmptyRowIsNotRecoverable() {
        XCTAssertNil(MessageRetryManager.recoverWirePlaintext(for: makeMessage(text: "")))
    }
}
