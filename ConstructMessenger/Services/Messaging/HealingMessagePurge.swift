//
//  HealingMessagePurge.swift
//  Construct Messenger
//
//  The `HealingMessage` entity, emptied.
//
//  It was written by `SessionHealingService.enqueue` — a JSON `ChatMessage` per failed
//  msgNum=0 carrier, with `healAttempts` and `lastAttemptAt` beside it — and it was read by
//  nothing. `pendingMessages(from:in:)` was its only reader and had no callers, so the promise
//  in its header ("so that an app restart during the healing attempt doesn't permanently lose
//  the message") was never kept: the rows went in and stayed there until the 24-hour prune.
//
//  The carrier the heal actually replays is the wire payload in `construct-core`'s healing
//  queue, which is CFE-persisted with the rest of the orchestrator state — binary, per device,
//  and restored on launch. Step 4 of `decisions/session-is-one-state-machine.md`.
//
//  The entity itself stays in the model: removing it is a data-model version, and this change
//  does not need one. What it must not do is leave the rows behind — a store that nobody writes
//  and nobody reads still occupies the place where someone would look.
//

import Foundation
import CoreData

enum HealingMessagePurge {

    private static let doneKey = "construct.healingMessage.purged.v1"

    /// Deletes every `HealingMessage` row, once per install.
    ///
    /// Once, because the entity has had no writer since 2026-09-23 — a repeated sweep would be a
    /// scan on every launch for rows that cannot come back. The flag is `UserDefaults` rather
    /// than a Core Data marker for the same reason: it is about this build, not about the data.
    static func runOnce(in context: NSManagedObjectContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let fetch = HealingMessage.fetchRequest()
        guard let rows = try? context.fetch(fetch) else { return }
        if !rows.isEmpty {
            Log.info("HealingMessage: purging \(rows.count) row(s) left by the pre-step-4 heal queue", category: "SessionHealing")
            rows.forEach { context.delete($0) }
            context.saveAndLog()
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
