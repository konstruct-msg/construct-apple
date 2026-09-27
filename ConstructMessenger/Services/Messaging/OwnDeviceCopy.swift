//
//  OwnDeviceCopy.swift
//  Construct Messenger
//
//  The encrypted payload of a SENDER_SYNC: the sending device's certificate beside the core's
//  wire payload (`Shared_Proto_Core_V1_OwnDeviceCopy`, construct-protos `core/envelope.proto`).
//

import Foundation
import SwiftProtobuf

/// Wraps and unwraps the one payload a copy to our own device carries.
///
/// A copy to a sibling goes unsealed (`SealingExemption.ownDevices`), so it has no `SealedInner`
/// to bring a sender certificate — and a sibling's first message opens a session only from one
/// (`decisions/first-message-opens-without-the-server.md`). Until 2026-09-27 the certificate was
/// simply absent, and the receive side had to fetch the sender's bundle; the change that removed
/// that fetch assumed a certificate the copy did not have, and every copy to a new sibling was
/// dropped (three-simulator stand, 2026-09-27).
enum OwnDeviceCopy {
    /// Every SENDER_SYNC goes out through this, with a certificate or without.
    ///
    /// `certificate` is the serialized proto the server issued. Absent or unreadable, the copy
    /// still goes: on an existing session it opens without one, and a first message then fails
    /// in the core with `SENDER_CERTIFICATE_MISSING` rather than never being sent.
    static func wrap(certificate: Data?, wirePayload: Data) -> Data {
        var copy = Shared_Proto_Core_V1_OwnDeviceCopy()
        copy.wirePayload = wirePayload
        if let certificate,
           let parsed = try? Shared_Proto_Core_V1_SenderCertificate(serializedBytes: certificate) {
            copy.senderCertificate = parsed
        }
        return (try? copy.serializedData()) ?? Data()
    }

    /// The wire payload and, when the sender had one, its certificate as the core takes it.
    ///
    /// Not verified here: the core checks the signature when — and only when — the certificate
    /// is used to open a session.
    static func unwrap(_ payload: Data) -> (certificate: SenderCertificate?, wirePayload: Data)? {
        guard let copy = try? Shared_Proto_Core_V1_OwnDeviceCopy(serializedBytes: payload),
              !copy.wirePayload.isEmpty else { return nil }
        let certificate = copy.hasSenderCertificate
            ? SenderCertificate(proto: copy.senderCertificate)
            : nil
        return (certificate, copy.wirePayload)
    }

    /// A received SENDER_SYNC as the router takes it — the one builder for the live stream and
    /// the pending page, so the two cannot come to differ on which fields the copy brings.
    /// `nil` when the payload is not a copy or its wire payload does not decode.
    static func message(
        id: String,
        from: String,
        to: String,
        timestamp: UInt64,
        serverOrderKey: String?,
        conversationId: String,
        payload: Data
    ) -> ChatMessage? {
        guard let copy = unwrap(payload),
              let decoded = try? WirePayloadCoder.decode(copy.wirePayload) else { return nil }
        return ChatMessage(
            id: id,
            from: from,
            to: to,
            ephemeralPublicKey: Data(decoded.ephemeralPublicKey),
            messageNumber: decoded.messageNumber,
            content: decoded.content,
            suiteId: decoded.suiteId,
            timestamp: timestamp,
            serverOrderKey: serverOrderKey,
            oneTimePreKeyId: decoded.oneTimePreKeyId,
            kemCiphertext: decoded.kemCiphertext ?? Data(),
            contentType: UInt8(Shared_Proto_Core_V1_ContentType.senderSync.rawValue),
            kyberOtpkId: decoded.kyberOtpkId,
            pqMessageEpoch: decoded.pqMessageEpoch,
            pqRatchetField: decoded.pqRatchetField,
            // The relay blanks `sender_device`; the copy's certificate names the sibling.
            senderDeviceId: copy.certificate?.deviceId ?? "",
            // A sibling's first message opens a session from it, like a sealed one.
            senderCertificate: copy.certificate,
            conversationId: conversationId,
            rawPayload: copy.wirePayload
        )
    }
}

extension SenderCertificate {
    /// The server's certificate as the core takes it — one field list for both carriers, the
    /// sealed inner and the own-device copy.
    init(proto cert: Shared_Proto_Core_V1_SenderCertificate) {
        self.init(
            userId: cert.senderUserID,
            domain: cert.senderDomain,
            identityKey: cert.senderIdentityKey,
            deviceId: cert.senderDeviceID,
            issuedAt: cert.issuedAt,
            expiresAt: cert.expiresAt,
            signature: cert.serverSignature
        )
    }
}
