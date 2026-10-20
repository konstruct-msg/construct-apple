//
//  BlockedContacts.swift
//  Construct Messenger
//
//  Client-side block enforcement lookup, used by MessageRouter.
//

import Foundation

/// Client-side block enforcement lookup.
///
/// Under Ghost Mode (sealed sender) the server cannot see the sender of a sealed message,
/// so it does NOT apply server-side block/ban on the default send path — the sealed branch
/// returns before the block check (construct-server messaging-service/grpc.rs). Blocking is
/// therefore enforced client-side, by dropping incoming messages from blocked contacts AFTER
/// they are unsealed/decrypted (the ratchet still advances, so unblocking resumes cleanly).
/// This is the load-bearing block mechanism and the shape the unauthenticated sealed-sender
/// endgame requires — the server can never enforce it there.
///
/// See: construct-docs/decisions/sealed-sender-authenticated-transitional.md
enum BlockedContacts {
    /// Whether `userId` is a blocked contact. One indexed read of saved state; safe on the
    /// incoming-message hot path. Empty/unknown ids → not blocked (fail-open: a block is a
    /// user-initiated suppression, not a boundary whose lookup failure should drop legitimate
    /// traffic).
    static func isBlocked(_ userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return (try? LocalRepositories.contacts.isBlocked(userId)) ?? false
    }
}
