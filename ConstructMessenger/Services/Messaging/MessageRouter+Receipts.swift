//
//  MessageRouter+Receipts.swift
//  Construct Messenger
//
//  MessageRouter: E2E delivery/read receipt handling and the special-message dispatch.
//

import Foundation
import CoreData
import SwiftProtobuf

@MainActor
extension MessageRouter {
    // MARK: - E2E Delivery Receipts

    /// Parse and dispatch an incoming E2E delivery receipt (content_type=14).
    ///
    /// Payload is binary proto `Shared_Proto_Signaling_V1_DeliveryReceipt` with
    /// `.direct(DirectReceipt{ messageIds, ... })`. The legacy JSON payload
    /// (`{"type":"delivery_receipt",…}`) was retired once all clients emitted proto
    /// (producer flipped 2026-06-11); a stale JSON payload now fails proto parse and is
    /// discarded — never rendered, since ct=14 is intercepted before the chunk reassembler
    /// and `Message.isServiceArtifact` guards any leak.
    func handleIncomingE2EDeliveryReceipt(
        _ payload: Data,
        messageId: String,
        from otherUserId: String,
        in context: NSManagedObjectContext
    ) {
        // No receipt for a receipt: ct=14 has no row on the sender's side, and answering one
        // receipt with another is the shape of a loop.
        defer {
            PersistentACKStore.shared.markProcessed(messageId, senderId: otherUserId)
        }

        guard !payload.isEmpty else {
            Log.error("E2E receipt: empty payload from \(otherUserId.prefix(8))…", category: "MessageRouter")
            return
        }

        let ids = parseBinaryReceipt(payload, from: otherUserId) ?? []

        guard !ids.isEmpty else {
            Log.error("E2E receipt: failed to parse payload from \(otherUserId.prefix(8))…", category: "MessageRouter")
            return
        }

        Log.info("E2E receipt: \(ids.count) message(s) confirmed by \(otherUserId.prefix(8))…", category: "MessageRouter")
        delegate?.messageRouter(self, didDecryptDeliveryReceipt: ids)
    }

    /// Parse binary proto delivery receipt: `Shared_Proto_Signaling_V1_DeliveryReceipt`
    private func parseBinaryReceipt(_ payload: Data, from otherUserId: String) -> [String]? {
        do {
            let receipt = try Shared_Proto_Signaling_V1_DeliveryReceipt(serializedBytes: payload)
            switch receipt.receiptType {
            case .direct(let direct):
                guard !direct.messageIds.isEmpty else {
                    Log.error("E2E receipt: empty messageIds in binary proto from \(otherUserId.prefix(8))…", category: "MessageRouter")
                    return nil
                }
                return direct.messageIds
            case .group:
                Log.info("E2E receipt: group receipt received (not yet supported) from \(otherUserId.prefix(8))…", category: "MessageRouter")
                return nil
            case nil:
                Log.error("E2E receipt: no receiptType in binary proto from \(otherUserId.prefix(8))…", category: "MessageRouter")
                return nil
            }
        } catch {
            Log.error("E2E receipt: binary proto parse failed from \(otherUserId.prefix(8))…: \(error)", category: "MessageRouter")
            return nil
        }
    }

    /// Handle special message types (profile, etc.)
    /// - Returns: true if special message was handled
    func handleSpecialMessage(
        _ decryptedContent: String,
        from userId: String,
        in context: NSManagedObjectContext
    ) -> Bool? {
        // Check for profile message
        if decryptedContent.trimmingCharacters(in: .whitespaces).hasPrefix("{"),
           let jsonData = decryptedContent.data(using: .utf8) {
            let jsonDict: [String: Any]
            do {
                guard let parsed = try parseJSONObject(jsonData, category: "MessageRouter", context: "special message") else {
                    return false
                }
                jsonDict = parsed
            } catch {
                return false
            }
            guard let type = jsonDict["type"] as? String else {
                return false
            }

            if type == "profile" {
                if let profileData = ProfileSharingManager.shared.parseProfileMessage(decryptedContent) ??
                                     (decryptedContent.data(using: .utf8).flatMap { ProfileSharingManager.shared.parseProfileMessage(from: $0) }) {
                    Log.info("Received profile message from \(userId)", category: "MessageRouter")
                    ProfileSharingManager.shared.handleProfileMessage(profileData, from: userId)
                    return true
                } else {
                    Log.info("Failed to parse profile message from \(userId), skipping", category: "MessageRouter")
                    return true
                }
            }
        }

        return false
    }
}
