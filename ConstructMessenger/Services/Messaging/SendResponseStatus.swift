//
//  SendResponseStatus.swift
//  Construct Messenger
//
//  What the server's answer to a send leaves the message as. One reading for the first send,
//  every retry and the session resend (TODO 180). Until 2026-10-20 each kept its own switch over
//  the status string; the session resend marked a rate-limited copy failed where every other path
//  queued it.
//

import Foundation

extension SendMessageResponse {
    /// The message's state after this answer: a refusal is queued when the server says it is worth
    /// trying again (rate limit), failed when it is not (blocked, a refused ciphertext).
    var deliveryStatus: DeliveryStatus {
        switch status.lowercased() {
        case "delivered":          return .delivered
        case "queued":             return .queued
        case "failed", "blocked":  return retryable ? .queued : .failed
        default:                   return .sent
        }
    }

    /// The server refused the ciphertext itself, which names the ratchet that wrote it — ours to
    /// retire before the next send.
    var refusedCiphertext: Bool {
        status.lowercased() == "failed" && errorCode == "encryptionFailed"
    }

    /// A status the server is not known to send. Read as `.sent`, and worth a log line.
    var isUnknownStatus: Bool {
        !["delivered", "queued", "failed", "blocked", "sent", "success"].contains(status.lowercased())
    }
}

/// What every send path does when the server refuses a ciphertext: drop the stored copy — it was
/// written by the refused ratchet — and retire that ratchet with each device that refused, so the
/// next send opens a new one. The peer is told nothing; nothing it holds is wrong.
///
/// Until 2026-10-20 only the first send did this. A retry or a resend that met the same refusal
/// marked the message failed and kept the ratchet, so a manual retry encrypted on it again and was
/// refused again (TODO 180).
enum CiphertextRefusal {
    /// The devices whose copy was refused, or nil when the server refused no ciphertext. Empty
    /// means the refusal named no device; the caller then retires every device of the peer.
    static func refusedDevices(in report: RecipientSendReport) -> [String]? {
        guard report.status.refusedCiphertext else { return nil }
        return report.copies.filter { $0.response?.refusedCiphertext ?? false }.map(\.deviceId)
    }

    /// Acts on a refusal, if there was one. Returns whether it did.
    @MainActor
    @discardableResult
    static func retireIfRefused(_ report: RecipientSendReport, messageId: String, recipientId: String, trace: String = "") -> Bool {
        guard let refused = refusedDevices(in: report) else { return false }
        OutgoingWirePayloadStore.shared.remove(baseMessageId: messageId)
        Log.error("encryptionFailed from server — retiring our state with \(recipientId.prefix(8))… devices=\(refused.map { $0.prefix(8) })\(trace)", category: "CiphertextRefusal")
        SessionLifecycleController.shared.resetSession(
            with: recipientId,
            devices: refused.isEmpty ? nil : refused,
            reason: "server_encryption_rejected"
        )
        return true
    }
}
