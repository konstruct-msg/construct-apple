//
//  SenderSyncRouting.swift
//  Construct Messenger
//
//  The routing header carried inside the SENDER_SYNC ciphertext.
//

import Foundation

/// Which conversation a SENDER_SYNC copy belongs to, carried where the server cannot read it.
///
/// SENDER_SYNC is the copy of an outgoing message that a device sends to the sender's *own* other
/// devices, so they can show it as a sent bubble. Placing it needs one fact the envelope does not
/// supply: who the other party of that conversation is. Sender and recipient on the wire are both
/// the local user.
///
/// It used to be read from `Envelope.conversation_id`, which the server blanks on delivery — on
/// purpose, and correctly:
///
///     // messaging-service/src/envelope.rs
///     // conversation_id is intentionally empty: it is server-visible metadata
///     // and must not carry E2E semantics.
///     conversation_id: String::new(),
///
/// So every SENDER_SYNC ever sent was unroutable, on both sides of a single account, since the
/// feature shipped. Observed 2026-08-05 and again 2026-08-17, three of three in one session. The
/// contradiction was not a relay bug: the message routed on metadata the server is designed never
/// to deliver. The fix is to stop asking the server for it.
///
/// **The sender's device is deliberately not in here.** It is needed *before* decryption — it
/// selects the Double Ratchet session — so it cannot travel inside the ciphertext it would be used
/// to open. The receiver learns it by trying its own-device sessions; the one that decrypts is the
/// answer, and it is a cryptographic answer rather than a claim. Putting it in this header as well
/// would create a second carrier for a fact the session already settles, which is the defect class
/// this codebase keeps paying for.
///
/// Layout — fixed 20 bytes, no length fields because both parts are fixed width:
///
///     magic "SSR1"   [4]
///     partner UUID   [16]   raw bytes, same encoding as the message id in the KNST header
///
/// Prepended to the plaintext *before* KNST chunking, so a multi-chunk sync carries it once and
/// the receiver strips it once, after reassembly.
struct SenderSyncRouting: Equatable {

    /// The other party of the conversation this message belongs to — a `ServerUserId`.
    let partnerUserId: String

    static let magic: [UInt8] = Array("SSR1".utf8)
    static let headerSize = 4 + 16

    /// The header bytes, or `nil` when `partnerUserId` is not a UUID.
    ///
    /// `nil` rather than a best-effort encoding: a malformed header on the wire would be stripped
    /// as if it were valid and would take the first bytes of the message with it. The caller sends
    /// without a header instead, which lands on the same unroutable path as an old sender — no
    /// worse than before this existed.
    func encoded() -> Data? {
        guard let uuid = UUID(uuidString: partnerUserId) else { return nil }
        var data = Data(capacity: Self.headerSize)
        data.append(contentsOf: Self.magic)
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
        return data
    }

    /// Split a reassembled SENDER_SYNC plaintext into its routing header and the content after it.
    ///
    /// Returns `nil` when the header is absent — which is exactly what a sender running a build
    /// from before this change produces. The caller then behaves as it did then.
    static func decode(prefixOf data: Data) -> (routing: SenderSyncRouting, remainder: Data)? {
        guard data.count >= headerSize else { return nil }
        guard data.prefix(magic.count).elementsEqual(magic) else { return nil }

        let b = [UInt8](data.subdata(in: (data.startIndex + magic.count)..<(data.startIndex + headerSize)))
        guard b.count == 16 else { return nil }
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        // The all-zero UUID is what malformed bytes decode to. It is not a user id, and treating it
        // as one would route every damaged sync into one phantom conversation.
        guard uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else { return nil }

        let remainder = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        return (SenderSyncRouting(partnerUserId: uuid.uuidString.lowercased()), remainder)
    }
}
