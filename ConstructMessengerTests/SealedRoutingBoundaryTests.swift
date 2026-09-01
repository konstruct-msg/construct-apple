//
//  SealedRoutingBoundaryTests.swift
//  ConstructMessengerTests
//
//  The composition that `f39e03b4` broke and that nothing could catch: seal a control message,
//  unseal it, route it. Sealed END_SESSION and SESSION_RESET_INIT were silently dropped on the
//  recipient for four days with the entire suite green, because
//
//    • `MessageStreamParser.parse` was never executed by a test, and
//    • `MessageRouter.routeIncomingMessage` was never driven with a SEALED message, so the
//      unseal-boundary remap (`messageType` from the recovered `contentType`) had no coverage.
//
//  Both are exercised here against the real production functions. The acceptance criterion is
//  mutation-based: revert the remap in MessageRouter or drop `rawPayload` in the parser's sealed
//  fallback, and this file must go red.
//
//  See client/ios/SEALED_CONTROL_CHANNEL_REMEDIATION.md.
//

import XCTest
import CoreData
import SwiftProtobuf
@testable import Construct_Messenger

@MainActor
final class SealedRoutingBoundaryTests: XCTestCase {

    // MARK: - Recording delegate

    /// Records the two delegate queries that are unique to the control branches and fire
    /// *before* any crypto work, so classification can be observed without executing the
    /// handlers. Both return `true` to short-circuit the heavy path deliberately.
    private final class RecordingDelegate: MessageRouterDelegate {
        var resetInitSupersededQueries: [String] = []
        var endSessionStaleQueries: [String] = []
        var endSessionRequests: [String] = []

        func messageRouter(_ router: MessageRouter, needsPublicKeyBundle peer: PeerAddress, for message: ChatMessage) {}
        func messageRouter(_ router: MessageRouter, needsEndSession peer: PeerAddress) {
            endSessionRequests.append(peer.account)
        }
        func messageRouter(_ router: MessageRouter, receivedEndSession peer: PeerAddress, timestamp: UInt64) {}
        func messageRouter(_ router: MessageRouter, isEndSessionStale peer: PeerAddress, timestamp: UInt64) -> Bool {
            endSessionStaleQueries.append(peer.account)
            return true   // short-circuit: classification is what we assert
        }
        func messageRouter(_ router: MessageRouter, isResetInitSuperseded peer: PeerAddress, timestamp: UInt64, initEphemeral: Data) -> Bool {
            resetInitSupersededQueries.append(peer.account)
            return true   // short-circuit
        }
        func messageRouter(_ router: MessageRouter, didWinTieBreak peer: PeerAddress) {}
        func messageRouter(_ router: MessageRouter, needsSessionHeal peer: PeerAddress, failedMessage: ChatMessage) {}
        func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String]) {}
        func messageRouter(_ router: MessageRouter, needsUsernameUpdate peer: PeerAddress) {}
    }

    private var context: NSManagedObjectContext!
    private var router: MessageRouter!
    private var delegate: RecordingDelegate!
    private var savedUserId: String?
    private let me = UUID().uuidString
    private let peer = UUID().uuidString

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedUserId = AuthSessionManager.shared.currentUserId
        AuthSessionManager.shared.updateUserId(me)
        try CryptoCoreTestBootstrap.ensureCore(localUserId: me)

        context = CryptoCoreTestBootstrap.inMemoryContext()
        router = MessageRouter()
        router.setContext(context)
        delegate = RecordingDelegate()
        router.delegate = delegate
    }

    override func tearDown() {
        if let savedUserId, !savedUserId.isEmpty {
            AuthSessionManager.shared.updateUserId(savedUserId)
        }
        context = nil
        router = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - A. Unseal boundary remaps the routing kind

    /// A sealed SESSION_RESET_INIT must reach the SRI branch. Before the fix the outer
    /// "DIRECT_MESSAGE" stamp survived the rebuild, `isSessionResetInit` stayed false, and the
    /// message fell through to the generic decrypt path where the orchestrator returned no
    /// routing decision — the peer's session was never re-established.
    func testSealedResetInit_ReachesResetInitBranch() {
        stubUnseal(contentType: 24)

        router.routeIncomingMessage(sealedMessage(), in: context)

        XCTAssertEqual(
            delegate.resetInitSupersededQueries, [peer],
            "sealed ct=24 must route as SESSION_RESET_INIT — this is the f39e03b4 regression"
        )
    }

    /// A sealed END_SESSION must reach the END_SESSION branch. Before the fix it was classified
    /// as a regular message, failed to build an incoming event, and was skipped outright.
    func testSealedEndSession_ReachesEndSessionBranch() {
        stubUnseal(contentType: 21)

        router.routeIncomingMessage(sealedMessage(), in: context)

        XCTAssertEqual(
            delegate.endSessionStaleQueries, [peer],
            "sealed ct=21 must route as END_SESSION — this is the f39e03b4 regression"
        )
    }

    /// Control-branch classification must not swallow ordinary sealed traffic: a regular body
    /// takes neither control branch.
    func testSealedRegularMessage_TakesNeitherControlBranch() {
        stubUnseal(contentType: 1)

        router.routeIncomingMessage(sealedMessage(), in: context)

        XCTAssertTrue(delegate.resetInitSupersededQueries.isEmpty, "ct=1 is not a SESSION_RESET_INIT")
        XCTAssertTrue(delegate.endSessionStaleQueries.isEmpty, "ct=1 is not an END_SESSION")
    }

    /// The resolved sender must become the routing identity — a sealed message carries an empty
    /// `from`, and everything downstream keys off it.
    func testSealedMessage_RoutesUnderResolvedSender() {
        stubUnseal(contentType: 24)

        router.routeIncomingMessage(sealedMessage(), in: context)

        XCTAssertEqual(delegate.resetInitSupersededQueries.first, peer,
                       "routing identity must be the unsealed sender, not the empty outer `from`")
    }

    // MARK: - B. Parser preserves the sealed control payload

    /// A sealed END_SESSION carries a 16-byte SessionControl sentinel inside SealedInner — far
    /// shorter than a WirePayload, so `WirePayloadCoder.decode` fails and the parser takes its
    /// sealed fallback. That fallback used to drop the payload, which is what made the typed
    /// `SessionControl.reason` hint (e.g. `.otpkUnreproducible` → 3-DH re-init) unreadable.
    func testParser_SealedShortControlInner_PreservesRawPayload() throws {
        let sentinel = Data(repeating: 0xAB, count: 16)
        let response = sealedStreamResponse(innerPayload: sentinel)

        let event = MessageStreamParser.parse(response)

        guard case .message(let parsed, _)? = event else {
            return XCTFail("sealed envelope must parse into a .message event, got \(String(describing: event))")
        }
        XCTAssertEqual(parsed.rawPayload, sentinel,
                       "sealed fallback must carry the inner payload through — dropping it loses SessionControl.reason")
        XCTAssertTrue(parsed.from.isEmpty, "sender stays unresolved until MessageRouter unseals")
        XCTAssertFalse(parsed.sealedInnerData.isEmpty, "sealed bytes must survive for resolveSender")
    }

    /// Sanity companion: a sealed envelope whose inner IS a decodable WirePayload keeps its
    /// wire payload too, so the two fallback arms agree.
    func testParser_SealedEnvelope_AlwaysCarriesSealedInnerForResolution() throws {
        let response = sealedStreamResponse(innerPayload: Data(repeating: 0x07, count: 8))

        let event = MessageStreamParser.parse(response)

        guard case .message(let parsed, _)? = event else {
            return XCTFail("sealed envelope must parse into a .message event")
        }
        XCTAssertFalse(parsed.sealedInnerData.isEmpty)
    }

    // MARK: - Helpers

    private func stubUnseal(contentType: UInt8) {
        router.sealedSenderResolver = StubResolver(
            resolved: ResolvedSender(senderId: peer, contentType: contentType, trust: .vouched(.signature))
        )
    }

    /// Stands in for StealthSenderService: yields a known sender/content type without needing
    /// Keychain identity keys or a genuine sealed box.
    private struct StubResolver: SealedSenderResolving {
        let resolved: ResolvedSender?
        func resolveSender(sealedInnerBytes: Data) -> ResolvedSender? { resolved }
    }

    /// Post-parser shape of a sealed delivery: empty `from`, generic outer stamp, sealed bytes
    /// present. Exactly what `MessageStreamParser` hands to the router under stealth.
    private func sealedMessage(id: String = UUID().uuidString) -> ChatMessage {
        ChatMessage(
            id: id,
            from: "",
            to: me,
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            messageNumber: 0,
            content: Data(repeating: 2, count: 48),
            suiteId: 1,
            timestamp: UInt64(Date().timeIntervalSince1970),
            contentType: 1,                                   // outer is forced generic
            rawPayload: Data(repeating: 3, count: 64),
            sealedInnerData: Data(repeating: 4, count: 48)
        )
    }

    private func sealedStreamResponse(innerPayload: Data) -> Shared_Proto_Services_V1_MessageStreamResponse {
        var inner = Shared_Proto_Core_V1_SealedInner()
        inner.recipientUserID = me
        inner.encryptedPayload = innerPayload
        inner.contentType = .sessionReset

        var sealedEnvelope = Shared_Proto_Core_V1_SealedSenderEnvelope()
        sealedEnvelope.sealedInner = (try? inner.serializedData()) ?? Data()

        var envelope = Shared_Proto_Core_V1_Envelope()
        envelope.messageID = UUID().uuidString
        envelope.recipient.userID = me
        envelope.timestamp = Int64(Date().timeIntervalSince1970)
        envelope.contentType = .e2EeSignal            // server forces generic for sealed sends
        envelope.encryptedPayload = Data()            // payload rides inside SealedInner
        envelope.sealedSender = sealedEnvelope

        var response = Shared_Proto_Services_V1_MessageStreamResponse()
        response.message = envelope
        return response
    }
}

// MARK: - C. The rebuild carries every field it does not deliberately replace

/// Slice B of the pre-release consistency audit (decisions/pre-release-consistency-audit).
///
/// The unseal boundary replaces three things and must carry the rest verbatim. A field dropped
/// there is invisible — nothing fails, the value is simply zero downstream. Two were in fact
/// being dropped: `pqMessageEpoch` and `pqRatchetField`, read by the RESPONDER init to rebuild
/// the AEAD associated data, and whose loss its own comment records as "the outage".
final class SealedRebuildFieldPreservationTests: XCTestCase {

    private let peer = "7574fdec-ca31-44ac-9d43-0e6e870fe4d5"
    private let me = "0a1c609f-b37d-4d67-b7b2-b0f8ec16d167"

    /// Every field distinct and non-default, so a dropped one reads as a changed value rather
    /// than coinciding with the default it would fall back to.
    private func sealedCarrier() -> ChatMessage {
        ChatMessage(
            id: "6fcec8b4-c2ca-4e94-a8de-764b5623bcb6",
            from: "",
            to: "",
            ephemeralPublicKey: Data(repeating: 0x11, count: 32),
            messageNumber: 7,
            content: Data(repeating: 0x22, count: 48),
            suiteId: 3,
            timestamp: 1_785_665_817,
            oneTimePreKeyId: 1_003_750,
            kemCiphertext: Data(repeating: 0x33, count: 1088),
            contentType: 1,
            kyberOtpkId: 42,
            pqMessageEpoch: 9,
            pqRatchetField: Data(repeating: 0x44, count: 24),
            senderDeviceId: "651e765cbbd33b4e48631fb802c2b3d2",
            conversationId: "direct:a:b",
            replyToMessageId: "reply-target",
            rawPayload: Data(repeating: 0x55, count: 1428),
            sealedInnerData: Data(repeating: 0x66, count: 96)
        )
    }

    private func resolved(contentType: UInt8 = 24) -> ResolvedSender {
        ResolvedSender(senderId: peer, contentType: contentType, trust: .vouched(.signature))
    }

    // MARK: The regression

    /// Suite-3 PQ fields must survive. The sender encrypts with a `pq_message_epoch` tag in the
    /// associated data; a responder that rebuilds it from zeros produces different AD and cannot
    /// decrypt. Suite 3 is negotiated in the field, so these are populated on real carriers.
    func testPqRatchetFieldsSurviveTheUnsealBoundary() {
        let carrier = sealedCarrier()
        let rebuilt = carrier.resolvingSealedSender(resolved(), currentUserId: me)

        XCTAssertEqual(rebuilt.pqMessageEpoch, 9,
                       "suite-3 epoch tag dropped — RESPONDER init rebuilds the wrong AEAD AD")
        XCTAssertEqual(rebuilt.pqRatchetField, carrier.pqRatchetField,
                       "suite-3 sparse PQ field dropped — same failure, silent")
    }

    // MARK: Everything else carried through

    func testAllCarriedFieldsAreUnchanged() {
        let carrier = sealedCarrier()
        let rebuilt = carrier.resolvingSealedSender(resolved(), currentUserId: me)

        XCTAssertEqual(rebuilt.id, carrier.id)
        XCTAssertEqual(rebuilt.ephemeralPublicKey, carrier.ephemeralPublicKey)
        XCTAssertEqual(rebuilt.messageNumber, carrier.messageNumber)
        XCTAssertEqual(rebuilt.content, carrier.content)
        XCTAssertEqual(rebuilt.suiteId, carrier.suiteId, "suite drives the AD layout — must not shift")
        XCTAssertEqual(rebuilt.timestamp, carrier.timestamp)
        XCTAssertEqual(rebuilt.oneTimePreKeyId, carrier.oneTimePreKeyId, "X3DH OTPK id — init fails without it")
        XCTAssertEqual(rebuilt.kemCiphertext, carrier.kemCiphertext, "PQXDH decapsulation input")
        XCTAssertEqual(rebuilt.kyberOtpkId, carrier.kyberOtpkId, "selects SPK vs one-time Kyber secret")
        XCTAssertEqual(rebuilt.senderDeviceId, carrier.senderDeviceId)
        XCTAssertEqual(rebuilt.conversationId, carrier.conversationId)
        XCTAssertEqual(rebuilt.replyToMessageId, carrier.replyToMessageId)
        XCTAssertEqual(rebuilt.rawPayload, carrier.rawPayload, "the orchestrator's decrypt input")
    }

    // MARK: The three deliberate replacements

    func testSenderIsReplacedByTheResolvedIdentity() {
        let rebuilt = sealedCarrier().resolvingSealedSender(resolved(), currentUserId: me)
        XCTAssertEqual(rebuilt.from, peer, "sealed `from` is empty on the wire — resolution fills it")
    }

    func testContentTypeAndKindComeFromTheSealedInner() {
        let rebuilt = sealedCarrier().resolvingSealedSender(resolved(contentType: 24), currentUserId: me)
        XCTAssertEqual(rebuilt.contentType, 24, "outer type is forced generic; the inner one is authoritative")
        // The kind is derived, not stored: `messageType` was removed on 2026-08-02, so there is
        // no longer a second field that could stay stamped DIRECT while this byte says SRI.
        XCTAssertTrue(rebuilt.isSessionResetInit, "the recovered byte must drive the predicates")
    }

    func testSealedBytesAreDroppedOnceSpent() {
        let rebuilt = sealedCarrier().resolvingSealedSender(resolved(), currentUserId: me)
        XCTAssertTrue(rebuilt.sealedInnerData.isEmpty, "the only deliberate omission")
    }

    /// An empty `to` is filled from our own identity; a populated one is left alone.
    func testRecipientFilledOnlyWhenAbsent() {
        XCTAssertEqual(sealedCarrier().resolvingSealedSender(resolved(), currentUserId: me).to, me)

        var addressed = sealedCarrier()
        addressed = ChatMessage(
            id: addressed.id, from: addressed.from, to: "someone-else",
            ephemeralPublicKey: addressed.ephemeralPublicKey,
            messageNumber: addressed.messageNumber, content: addressed.content,
            suiteId: addressed.suiteId, timestamp: addressed.timestamp
        )
        XCTAssertEqual(addressed.resolvingSealedSender(resolved(), currentUserId: me).to, "someone-else")
    }
}
