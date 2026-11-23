//
//  NoteSaver.swift
//  Construct Messenger
//
//  "Save to notes" on a message (todo 279): a copy of what it says and holds, with whose it was
//  and when. Its files are fetched now — the server forgets them in days, and a note is for later.
//

import Foundation

enum NoteSaver {
    enum Outcome: Equatable, Sendable {
        case saved
        /// The note is there; a file of it could not be fetched, and may be gone for good.
        case savedWithoutFiles
    }

    /// A file a note's body names, as it is fetched.
    struct File: Equatable, Sendable {
        let mediaId: String
        let mediaUrl: String
        let mediaKey: Data
    }

    /// Whether `row` is something to keep: what a person wrote or sent, except a shared profile,
    /// whose meaning is its sender (`ForwardItem`).
    static func isSavable(_ row: TranscriptRow) -> Bool {
        ForwardItem.isForwardable(row)
            && ForwardItem.content(legacyBody: row.legacyBody, plainText: row.plainText, sticker: row.stickerReference) != nil
    }

    /// The note is written first: what is on this device already is kept whatever the network does.
    @MainActor
    static func save(
        _ row: TranscriptRow,
        sourceName: String?,
        notes: any NotesStore = LocalRepositories.notes,
        now: Date = Date(),
        fetch: (File) async throws -> Void = { file in
            _ = try await MediaManager.shared.downloadAndDecryptMedia(
                mediaId: file.mediaId, mediaUrl: file.mediaUrl, mediaKey: file.mediaKey
            )
        }
    ) async throws -> Outcome {
        let body = MessageDisplayCache.shared.payloadData(messageId: row.id)
        try notes.insert(Note(
            body: body, createdAt: now, sourceName: row.isSentByMe ? nil : sourceName, sourceAt: row.timestamp
        ))
        var outcome = Outcome.saved
        for file in files(legacyBody: row.legacyBody, plainText: row.plainText, sticker: row.stickerReference) {
            do {
                try await fetch(file)
            } catch {
                Log.error("NoteSaver: a file was not fetched — \(error)", category: "Notes")
                outcome = .savedWithoutFiles
            }
        }
        return outcome
    }

    static func files(legacyBody: String, plainText: String?, sticker: StickerReference?) -> [File] {
        let media: [ForwardMedia]
        switch ForwardItem.content(legacyBody: legacyBody, plainText: plainText, sticker: sticker) {
        case .media(let items, _): media = items
        case .files(let items, _): media = items
        case .voice(let audio, _, _): media = [audio]
        case .text, .sticker, nil: media = []
        }
        return media.map { File(mediaId: $0.mediaId, mediaUrl: $0.mediaUrl, mediaKey: $0.mediaKey) }
    }
}
