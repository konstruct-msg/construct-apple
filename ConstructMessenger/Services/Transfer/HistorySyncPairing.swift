//
//  HistorySyncPairing.swift
//  Construct Messenger
//
//  Derives a shared 6-digit Nearby-transfer PIN from the Flow B join handshake.
//  Both sides already know pending_device_id (QR) and user_id — no extra code entry.
//

import Foundation
import CryptoKit

enum HistorySyncPairing {
    /// Deterministic PIN for post-link history sync (same algorithm on phone + desktop).
    static func pin(pendingDeviceId: String, userId: String) -> String {
        let material = "ct_history_sync_v1:\(userId):\(pendingDeviceId)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let bytes = Array(digest)
        let raw = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return String(format: "%06d", Int(raw % 1_000_000))
    }
}