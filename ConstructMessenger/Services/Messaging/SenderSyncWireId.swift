//
//  SenderSyncWireId.swift
//  Construct Messenger
//
//  The wire id a SENDER_SYNC copy travels under, and the one thing it says.
//

import Foundation

/// Reading of the `-ss-<tag>` suffix `MultiDeviceSendCoordinator` puts on a SENDER_SYNC copy.
///
/// The suffix names the device the copy is **for**. That matters because delivery is not per
/// device: `messaging-service/src/core.rs` fans a message out with `fetch_recipient_device_ids`,
/// writing the same envelope to every one of the recipient's per-device streams. An account with
/// three devices therefore receives, on each of them, the two copies meant for the other two.
///
/// Recognising those costs a string compare here. Without it each foreign copy walks the whole
/// candidate-session list, fails every decrypt, and — on a first message — reaches for a key
/// bundle over the network, all for a message that was never ours to read.
///
/// This reads what is already on the wire; it puts nothing new there. The suffix has been part of
/// the id since multi-device shipped, and the server has always seen it.
enum SenderSyncWireId {

    private static let marker = "-ss-"

    /// The target device tag, or `nil` when the id is not a SENDER_SYNC wire id.
    ///
    /// Forms produced by the sender:
    ///
    ///     <uuid>-ss-<tag>          single chunk
    ///     <uuid>-ss-<tag>-c<n>     chunk n of many
    static func targetDeviceTag(of wireId: String) -> String? {
        guard let range = wireId.range(of: marker, options: .backwards) else { return nil }
        let rest = wireId[range.upperBound...]
        // Cut the chunk suffix. `-c` cannot occur inside a tag: it is hex.
        let tag = rest.range(of: "-c", options: .backwards).map { String(rest[..<$0.lowerBound]) }
            ?? String(rest)
        return tag.isEmpty ? nil : tag
    }

    /// Whether `tag` names `deviceId`.
    ///
    /// The sender writes `deviceId.prefix(8)`, so this is a prefix test rather than equality —
    /// comparing the whole id against a truncated tag would never match, and a copy of every
    /// message would be dropped as foreign.
    static func tag(matches deviceId: String, tag: String) -> Bool {
        !tag.isEmpty && deviceId.hasPrefix(tag)
    }
}
