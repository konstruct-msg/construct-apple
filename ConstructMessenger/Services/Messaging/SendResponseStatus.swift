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
