//
//  UnstructuredWait.swift
//  Construct Messenger
//
//  Wait for an unstructured `Task` without becoming un-cancellable yourself.
//
//  `Task.value` does not honour the *caller's* cancellation. Awaiting it from a cancelled task
//  keeps waiting until the awaited task finishes on its own. Inside a task group that is fatal:
//  a group cannot return until every child has completed, so one child sitting on `Task.value`
//  pins the entire group to that task's lifetime — and every timeout racing beside it becomes
//  advisory. The timeout still fires, on time; it just cannot leave the building.
//
//  Device log, 2026-08-10 07:34:13 — QUIC stream open, soft accept timeout 1.5s, hard 5.0s:
//
//      07:34:13  openStream transport=QUIC → ams.konstruct.cc:443
//      07:34:43  QUIC recv pump error: Transport("recv_response: Connection error: Timeout")
//      07:34:44  MessageStream open timed out — reconnecting
//      07:34:44  MessageStream reconnecting in 1.7s (attempt #1, took 31740ms)
//
//  The 1.5s racer threw at 07:34:14.5. The failover it decided on happened 29 seconds later,
//  when quinn's own connection timeout finally released the child that was holding the group.
//  Everything in between — a send that failed "Stream unexpectedly closed", a background fetch
//  that gave up, VEIL escalation — ran in a window the app had already decided to abandon.
//
//  Two existing sites in this codebase had already paid for this lesson and written it down
//  (`GRPCCallExecutor.executeOnPersistentClient`, `MessageStreamManager.connectLoop`); each
//  solved it locally with a bespoke sleep-plus-watcher. This is that idiom with a name, so the
//  third site doesn't have to rediscover it and a test can reach it.
//

import Foundation

enum UnstructuredWait {

    /// Wait for `task` to finish, and stop waiting if *this* task is cancelled.
    ///
    /// The awaited task is left running — cancelling the wait is not a statement about the work.
    /// Use this inside a task group, where `cancelAll()` on the success path must not reach
    /// through and kill the very task the group just decided had succeeded.
    ///
    /// Throws `CancellationError` when the caller is cancelled, otherwise whatever `task` threw.
    static func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        let (finished, continuation) = AsyncStream<Void>.makeStream()
        // The watcher is deliberately unstructured and deliberately not cancelled: it is a leaf
        // holding one continuation, and it must outlive us to close the stream if we walk away.
        Task { _ = try? await task.value; continuation.finish() }

        // Iteration ends on either edge — the watcher finishing, or this task being cancelled.
        // That is the whole point: `for await` checks cancellation where `Task.value` does not.
        for await _ in finished { }

        if Task.isCancelled { throw CancellationError() }
        // The watcher only finishes after `task` has completed, so this returns immediately.
        return try await task.value
    }

    /// Wait for `task`, and cancel it too if *this* task is cancelled.
    ///
    /// Use this where the wait and the work share a fate — a caller awaiting a stream it owns,
    /// whose cancellation means "tear this down", not "stop watching".
    static func cancellingValue<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await value(of: task)
        } onCancel: {
            task.cancel()
        }
    }
}
