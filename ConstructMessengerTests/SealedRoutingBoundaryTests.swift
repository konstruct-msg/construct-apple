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

/// Stands in for an unsealed certificate: the boundary carries it, the core checks it.
private func stubCertificate(account: String, device: String) -> SenderCertificate {
    SenderCertificate(
        userId: account, domain: "test.example", identityKey: Data(repeating: 0x07, count: 32),
        deviceId: device, issuedAt: 1, expiresAt: 2, signature: Data(repeating: 0x09, count: 64)
    )
}

@MainActor
final class SealedRoutingBoundaryTests: XCTestCase {

    // MARK: - Recording delegate

    /// Records the delegate call unique to the DECRYPTION_ERROR branch, which fires before any
    /// crypto work, so classification can be observed without the core. The END_SESSION and
    /// SESSION_RESET_INIT branches it once recorded beside it went on 2026-09-27
    /// (`decisions/sessions-renew-by-sending.md`).
    private final class RecordingDelegate: MessageRouterDelegate {
        var decryptionErrors: [(peer: PeerAddress, payload: Data)] = []

        func messageRouter(_ router: MessageRouter, canOpenReceiving peer: PeerAddress, for message: ChatMessage) {}
        func messageRouter(_ router: MessageRouter, receivedDecryptionError peer: PeerAddress, payload: Data) {
            decryptionErrors.append((peer, payload))
        }
        func messageRouter(_ router: MessageRouter, didDecryptDeliveryReceipt messageIds: [String]) {}
        func messageRouter(_ router: MessageRouter, needsUsernameUpdate peer: PeerAddress) {}
    }

    private var context: NSManagedObjectContext!
    private var router: MessageRouter!
    private var delegate: RecordingDelegate!
    private var savedUserId: String?
    private let me = UUID().uuidString
    private let peer = UUID().uuidString
    /// A `CryptoDeviceId`: 32 hex characters, the space every session key lives in.
    private let senderDevice = "651e765cbbd33b4e48631fb802c2b3d2"

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

    /// A sealed DECRYPTION_ERROR must reach its branch. The real content type rides only in
    /// `SealedInner`; read from the outer stamp it would be a regular message, fail to decrypt, and
    /// be answered with a decryption error of our own — the f39e03b4 class of regression.
    ///
    /// Mutation: drop the `isDecryptionError` early exit — this reddens.
    func testSealedDecryptionError_ReachesItsBranch() {
        stubUnseal(contentType: 28)

        let message = sealedMessage()
        router.routeIncomingMessage(message, in: context)

        XCTAssertEqual(delegate.decryptionErrors.map(\.peer.account), [peer],
                       "sealed ct=28 must route as a DECRYPTION_ERROR under the resolved sender")
        XCTAssertEqual(delegate.decryptionErrors.first?.payload, message.rawPayload,
                       "the core opens the box the peer sealed; nothing here may change it")
    }

    /// The error is about one device's record, and only the certificate names the device.
    func testSealedDecryptionError_NamesTheCertifiedDevice() {
        stubUnseal(contentType: 28)

        router.routeIncomingMessage(sealedMessage(), in: context)

        XCTAssertEqual(delegate.decryptionErrors.map(\.peer.device), [senderDevice])
    }

    /// END_SESSION (21) from an older build is acknowledged and nothing else: it named no state,
    /// so nothing could tell whether it was about the one we hold.
    ///
    /// Mutation: route 21 into the decryption-error branch — this reddens.
    func testSealedEndSession_IsAcknowledgedAndIgnored() {
        stubUnseal(contentType: 21)

        let message = sealedMessage()
        router.routeIncomingMessage(message, in: context)

        XCTAssertTrue(delegate.decryptionErrors.isEmpty)
        XCTAssertTrue(PersistentACKStore.shared.isProcessed(message.id, in: context))
    }

    /// Control-branch classification must not swallow ordinary sealed traffic.
    func testSealedRegularMessage_TakesNoControlBranch() {
        stubUnseal(contentType: 1)

        router.routeIncomingMessage(sealedMessage(), in: context)

        XCTAssertTrue(delegate.decryptionErrors.isEmpty, "ct=1 is not a DECRYPTION_ERROR")
    }

    // MARK: - B. Parser preserves the sealed control payload

    /// A sealed DECRYPTION_ERROR carries the core's sealed box inside SealedInner, not a
    /// WirePayload, so it has no `wire` summary and the parser keeps it only because it is sealed.
    /// That fallback used to drop the payload (END_SESSION's reason hint went unreadable that way);
    /// dropped now, the error would reach the core empty and be refused.
    func testParser_SealedShortControlInner_PreservesRawPayload() throws {
        let sentinel = Data(repeating: 0xAB, count: 16)
        let response = sealedStreamResponse(innerPayload: sentinel)

        let event = MessageStreamParser.parse(response)

        guard case .message(let parsed, _)? = event else {
            return XCTFail("sealed envelope must parse into a .message event, got \(String(describing: event))")
        }
        XCTAssertEqual(parsed.rawPayload, sentinel,
                       "sealed fallback must carry the inner payload through — dropping it loses the decryption error")
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
            resolved: ResolvedSender(
            senderId: peer,
            senderDeviceId: senderDevice,
            contentType: contentType,
            trust: .vouched(.signature),
            senderCertificate: stubCertificate(account: peer, device: senderDevice)
        )
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
        inner.contentType = .decryptionError

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
    private let senderDevice = "651e765cbbd33b4e48631fb802c2b3d2"

    /// Every field distinct and non-default, so a dropped one reads as a changed value rather
    /// than coinciding with the default it would fall back to.
    private func sealedCarrier() -> ChatMessage {
        ChatMessage(
            id: "6fcec8b4-c2ca-4e94-a8de-764b5623bcb6",
            from: "",
            to: "",
            timestamp: 1_785_665_817,
            contentType: 1,
            // Deliberately not `senderDevice`: the boundary must overwrite this, not keep it.
            senderDeviceId: "00000000000000000000000000000000",
            conversationId: "direct:a:b",
            replyToMessageId: "reply-target",
            // A suite-3 handshake at message 7 with a PQ epoch: every header field the old
            // parsed-field copies carried is in here, and is read from here.
            rawPayload: handBuiltWirePayload(
                messageNumber: 7,
                suiteId: 3,
                kemCiphertext: [UInt8](repeating: 0x33, count: 1568),
                pqMessageEpoch: 9
            ),
            sealedInnerData: Data(repeating: 0x66, count: 96)
        )
    }

    private func resolved(contentType: UInt8 = 24) -> ResolvedSender {
        ResolvedSender(
            senderId: peer,
            senderDeviceId: senderDevice,
            contentType: contentType,
            trust: .vouched(.signature),
            senderCertificate: certificate
        )
    }

    private var certificate: SenderCertificate { stubCertificate(account: peer, device: senderDevice) }

    // MARK: The regression

    /// Suite-3 PQ fields must survive. The sender encrypts with a `pq_message_epoch` tag in the
    /// associated data; a responder that rebuilds it from zeros produces different AD and cannot
    /// decrypt. Those fields now live only in `rawPayload`, and the boundary copies the message
    /// rather than listing fields — so what this pins is that the payload and the core's reading
    /// of it cross unchanged.
    func testThePayloadAndItsSummarySurviveTheUnsealBoundary() {
        let carrier = sealedCarrier()
        let rebuilt = carrier.resolvingSealedSender(resolved(), currentUserId: me)

        XCTAssertEqual(rebuilt.rawPayload, carrier.rawPayload, "the orchestrator's decrypt input")
        XCTAssertEqual(rebuilt.wire, carrier.wire)
        XCTAssertEqual(rebuilt.messageNumber, 7)
        XCTAssertEqual(rebuilt.initKind, .handshake, "a header at message 7 still opens")
    }

    // MARK: Everything else carried through

    func testAllCarriedFieldsAreUnchanged() {
        let carrier = sealedCarrier()
        let rebuilt = carrier.resolvingSealedSender(resolved(), currentUserId: me)

        XCTAssertEqual(rebuilt.id, carrier.id)
        XCTAssertEqual(rebuilt.timestamp, carrier.timestamp)
        XCTAssertEqual(rebuilt.conversationId, carrier.conversationId)
        XCTAssertEqual(rebuilt.replyToMessageId, carrier.replyToMessageId)
    }

    // MARK: The four deliberate replacements

    func testSenderIsReplacedByTheResolvedIdentity() {
        let rebuilt = sealedCarrier().resolvingSealedSender(resolved(), currentUserId: me)
        XCTAssertEqual(rebuilt.from, peer, "sealed `from` is empty on the wire — resolution fills it")
    }

    /// The relay blanks `Envelope.sender_device`, so the carrier reaching this boundary never
    /// names a device. The certificate does, and §D's whole purpose is that the decrypt asks that
    /// one session instead of walking the peer's devices — a value silently carried through from
    /// the blanked outer field would leave the walk in place and look identical.
    func testSendingDeviceIsReplacedByTheCertifiedOne() {
        let carrier = sealedCarrier()
        let rebuilt = carrier.resolvingSealedSender(resolved(), currentUserId: me)
        XCTAssertEqual(rebuilt.senderDeviceId, senderDevice,
                       "the sending device must come from the certificate, not the blanked envelope")
        XCTAssertNotEqual(rebuilt.senderDeviceId, carrier.senderDeviceId,
                          "carrying the outer value through would name the wrong session")
    }

    /// The certificate crosses the boundary: it is the only thing a first message can open a
    /// session from. Dropped here, every first contact would be refused as unsealed.
    func testTheCertificateCrossesTheBoundary() {
        let rebuilt = sealedCarrier().resolvingSealedSender(resolved(), currentUserId: me)
        XCTAssertEqual(rebuilt.senderCertificate, certificate)
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
        addressed.to = "someone-else"
        XCTAssertEqual(addressed.resolvingSealedSender(resolved(), currentUserId: me).to, "someone-else")
    }
}
