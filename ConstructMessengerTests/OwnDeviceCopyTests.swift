//
//  OwnDeviceCopyTests.swift
//  ConstructMessengerTests
//
//  A SENDER_SYNC from the sender's wrap, through the stream parser, to the core's open.
//
//  The step that made first messages open from a sender certificate (2026-09-27) was tested with a
//  copy that already carried one — built by hand, in the shape a sealed message has. A real copy
//  goes unsealed and carried none, so every copy to a new sibling was dropped, with the suite
//  green; the three-simulator stand found it the same day. These tests start from the bytes the
//  sender puts on the wire, so a copy that loses its certificate anywhere on the way fails here.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class OwnDeviceCopyTests: XCTestCase {

    private let account = "own-account"

    /// The whole path: `wrap` on the sender, `MessageStreamParser.parse` on the sibling, and the
    /// core opening the session from what the parser produced.
    func testASiblingsFirstCopyOpensFromTheCertificateItCarries() throws {
        let (sender, senderId) = try makeTestDevice()
        let (sibling, siblingId) = try makeTestDevice()
        _ = try sender.initSession(contactId: siblingId, recipientBundle: try sibling.pqxdhTestBundle())
        let wire = try sender.encryptToWire(contactId: siblingId, plaintext: Data("copy".utf8))

        let certificate = try TestCertificateServer.shared.certificate(for: sender, account: account)
        let payload = try OwnDeviceCopy.wrap(certificate: try serialized(certificate), wirePayload: wire)
        let message = try XCTUnwrap(parsed(payload), "a wrapped copy parses into a message")

        XCTAssertEqual(message.rawPayload, wire, "the core gets the wire payload, not the wrapper")
        XCTAssertEqual(message.senderDeviceId, senderId, "the certificate names the sibling the relay blanked")
        let carried = try XCTUnwrap(message.senderCertificate, "the certificate survives the parser")

        TestCertificateServer.shared.trust(in: sibling)
        let opened = try sibling.initReceivingSessionFromWirePayload(
            senderCertificate: carried,
            wirePayload: message.rawPayload
        )
        XCTAssertEqual(opened.decryptedMessage, Data("copy".utf8))
        XCTAssertTrue(sibling.hasSession(contactId: senderId), "filed under the device the certificate names")
    }

    /// This client sends no copy without a certificate; one that arrives from a client that does
    /// must still parse, so the receive path can count it instead of losing it in the parser.
    func testACopyWithoutACertificateStillParses() throws {
        let wire = try midRatchetWire()
        var bare = Shared_Proto_Core_V1_OwnDeviceCopy()
        bare.wirePayload = wire
        let message = try XCTUnwrap(parsed(try bare.serializedData()))

        XCTAssertNil(message.senderCertificate)
        XCTAssertEqual(message.senderDeviceId, "")
        XCTAssertEqual(message.rawPayload, wire)
    }

    /// Bytes that are not a certificate would send a copy that names nobody.
    func testACopyIsNotWrappedAroundBytesThatAreNotACertificate() throws {
        XCTAssertThrowsError(try OwnDeviceCopy.wrap(certificate: Data([0xFF, 0xFF, 0xFF]), wirePayload: Data([1])))
    }

    /// The format before 2026-09-27 — a bare wire payload — is not a copy. Early alpha: no
    /// compatibility is kept, and a guess at which format it is would be a second carrier.
    func testABareWirePayloadIsNotACopy() throws {
        XCTAssertNil(OwnDeviceCopy.unwrap(try midRatchetWire()))
    }

    // MARK: - Helpers

    /// A well-formed wire payload of a message inside a ratchet — a responder's reply: it carries
    /// no handshake header, so it decodes and opens nothing.
    private func midRatchetWire() throws -> Data {
        let (alice, aliceId) = try makeTestDevice()
        let (bob, bobId) = try makeTestDevice()
        _ = try alice.initSession(contactId: bobId, recipientBundle: try bob.pqxdhTestBundle())
        let first = try alice.encryptToWire(contactId: bobId, plaintext: Data("first".utf8))
        _ = try bob.pqxdhTestReceive(from: alice, first: first)
        return try bob.encryptToWire(contactId: aliceId, plaintext: Data("reply".utf8))
    }

    private func serialized(_ certificate: SenderCertificate) throws -> Data {
        var proto = Shared_Proto_Core_V1_SenderCertificate()
        proto.senderUserID = certificate.userId
        proto.senderDomain = certificate.domain
        proto.senderIdentityKey = certificate.identityKey
        proto.senderDeviceID = certificate.deviceId
        proto.issuedAt = certificate.issuedAt
        proto.expiresAt = certificate.expiresAt
        proto.serverSignature = certificate.signature
        return try proto.serializedData()
    }

    private func parsed(_ payload: Data) -> ChatMessage? {
        var envelope = Shared_Proto_Core_V1_Envelope()
        envelope.messageID = UUID().uuidString
        envelope.sender.userID = account
        envelope.recipient.userID = account
        envelope.timestamp = Int64(Date().timeIntervalSince1970)
        envelope.contentType = .senderSync
        envelope.encryptedPayload = payload

        var response = Shared_Proto_Services_V1_MessageStreamResponse()
        response.message = envelope
        guard case .message(let message, _)? = MessageStreamParser.parse(response) else { return nil }
        return message
    }
}
