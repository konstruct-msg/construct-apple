//
//  TranscriptSignature.swift
//  Construct Messenger
//
//  What has to change before the whole transcript array is republished to the UI.
//
//  The flicker: on a long chat, every message caused the entire `messages` array to be reassigned
//  two to four times within one second. Device log, 2026-08-11, one incoming message on a 69-row
//  transcript:
//
//      10:49:20  FRC updated: 69 message(s) in window
//      10:49:20  FRC updated: 69 message(s) in window
//      10:49:20  FRC updated: 69 message(s) in window
//      10:49:20  FRC updated: 69 message(s) in window
//
//  Those are four distinct Core Data saves — insert, then delivery-status writes — each of which
//  changed the old fingerprint, because it hashed `deliveryStatusRaw`, `isEdited`, `timestamp` and
//  `transcriptText` alongside the ids. Each one re-derived the window and reassigned the array, and
//  `ChatMessageStore` already carried the note explaining what that costs: reassigning "forces
//  LazyVStack identity churn and black flashes". The cost scales with the number of rows, which is
//  why the flicker only shows up once a chat is long.
//
//  It was also unnecessary. `MessageBubbleRegularView` declares `@ObservedObject var message:
//  Message`, so a row already re-renders itself when its own managed object changes. Delivery
//  status, edit flag and a transcript arriving after speech-to-text all reach the screen through
//  that path, with no array involved.
//
//  So the array is republished only when the *set or order of rows* changes: an insert, a delete,
//  a reorder. Everything else is one row's business.
//

import Foundation

enum TranscriptSignature {

    /// Structural signature of a transcript window: which rows, in which order.
    ///
    /// Deliberately excludes every per-row field. Each exclusion is safe for one specific reason,
    /// and they are not interchangeable:
    ///
    /// - `deliveryStatusRaw`, `isEdited`, `transcriptText` — the row observes its own `Message`.
    /// - `timestamp` — a changed timestamp re-sorts the fetch, which changes the id order, which
    ///   this signature does capture.
    ///
    /// Known gap, stated rather than hidden: `ChatView.filteredMessages` filters on `displayText`
    /// while a search is active. An edit that changes text without changing the row set will not
    /// re-run that filter until the next structural change. That is a stale search result on an
    /// edited message, against four full-array rebuilds per message on every long chat.
    static func of(ids: [String]) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(ids.count)
        for id in ids { hasher.combine(id) }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
