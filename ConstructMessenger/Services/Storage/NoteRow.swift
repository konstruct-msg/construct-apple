//
//  NoteRow.swift
//  Construct Messenger
//
//  A note as a transcript row, so a note's pictures, files, voice and stickers are drawn by what
//  draws a message's (todo 279). The row's id is the note's under a prefix: `MessageDisplayCache`
//  reads a body by row id, and the prefix says it is a note's.
//

import Foundation

enum NoteRow {
    private static let prefix = "note:"

    static func rowId(_ noteId: String) -> String { prefix + noteId }

    /// The note a row id names; nil when it names a message.
    static func noteId(_ rowId: String) -> String? {
        rowId.hasPrefix(prefix) ? String(rowId.dropFirst(prefix.count)) : nil
    }
}

extension TranscriptRow {
    /// `note` as the bubbles read a row: ours, delivered, in no chat.
    init(note: Note) {
        let record = MessageRecord(note: note)
        MessageDisplayCache.shared.hold(record)
        // The edit moves the revision, so a view holding the old row draws again.
        self.init(record, revision: note.editedAt.map { Int($0.unixMs) } ?? 0)
    }
}

extension MessageRecord {
    init(note: Note) {
        self.init(
            id: NoteRow.rowId(note.id), chatId: "", fromUserId: "", toUserId: "", isSentByMe: true,
            timestamp: note.createdAt, orderKey: "", body: note.body, contentType: .regular,
            deliveryStatus: .delivered, retryCount: 0, suiteId: 0, isEdited: note.editedAt != nil, editedAt: note.editedAt
        )
    }
}
