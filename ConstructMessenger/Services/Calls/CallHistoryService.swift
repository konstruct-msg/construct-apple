//
//  CallHistoryService.swift
//  Construct Messenger
//
//  Writes a call to the log when it ends (`CallManager.endActiveCall`), through the call store
//  (`LocalRepositories.calls`).
//
//  iOS and Desktop alike (Desktop since 2026-10-29; calls there since 2026-10-21).
//

import Foundation

@MainActor
final class CallHistoryService {
    static let shared = CallHistoryService()

    private let store: () -> any CallStore

    private init() {
        self.store = { LocalRepositories.calls }
    }

    // MARK: - Save

    func record(
        session: CallSession,
        status: CallRecord.Status,
        startedAt: Date,
        durationSeconds: Int32
    ) {
        let call = CallRecord(
            id: session.id,
            peerUserId: session.peerUserId,
            peerName: session.peerName,
            direction: session.direction == .outgoing ? .outgoing : .incoming,
            status: status,
            startedAt: startedAt,
            endedAt: Date(),
            durationSeconds: durationSeconds
        )
        do {
            try store().upsert(call)
        } catch {
            Log.error("Failed to record call: \(error)", category: "CallHistory")
            return
        }
        // The call in its conversation (`CallTranscript`); the log row above is what it reads.
        guard let ownUserId = AuthSessionManager.shared.currentUserId else {
            Log.error("Call \(call.id.prefix(8))… logged with no account — not in the chat", category: "CallHistory")
            return
        }
        do {
            try CallTranscript.write(call, announce: true, ownUserId: ownUserId)
        } catch {
            Log.error("Call \(call.id.prefix(8))… not written into the chat: \(error)", category: "CallHistory")
        }
    }

    // MARK: - Delete

    /// The call, and its row in the conversation: a row whose call is gone would show nothing.
    func delete(_ id: String) {
        do {
            let call = try store().call(id)
            try store().delete(id)
            if let call { Self.deleteRows(of: [call]) }
        } catch {
            Log.error("Failed to delete call record: \(error)", category: "CallHistory")
        }
    }

    /// The whole log, in one store write (`CallStore.deleteAll`).
    func deleteAll() {
        do {
            let calls = try store().calls(limit: Int(Int32.max))
            let removed = try store().deleteAll()
            Self.deleteRows(of: calls)
            Log.info("Deleted \(removed) call history records", category: "CallHistory")
        } catch {
            Log.error("Failed to delete call history: \(error)", category: "CallHistory")
        }
    }

    /// The transcript rows of `calls`, and the previews of the chats they stood in.
    nonisolated static func deleteRows(
        of calls: [CallRecord],
        messages: any MessageStore = LocalRepositories.messages,
        chats: any ChatStore = LocalRepositories.chats
    ) {
        guard !calls.isEmpty else { return }
        do {
            try messages.delete(Set(calls.map { CallTranscript.messageId(callId: $0.id) }))
            for peer in Set(calls.map(\.peerUserId)) {
                guard let chat = try chats.chat(withPeer: peer) else { continue }
                MessagePersistenceService.refreshPreview(ofChat: chat.id, store: messages, chats: chats)
            }
        } catch {
            Log.error("Call rows not deleted from the chats: \(error)", category: "CallHistory")
        }
    }
}

