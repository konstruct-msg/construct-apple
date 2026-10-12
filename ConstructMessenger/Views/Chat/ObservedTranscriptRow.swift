//
//  ObservedTranscriptRow.swift
//  Construct Messenger
//
//  Reads a transcript entry's row in its own body, so a status, an edit or a body read late redraws
//  this row alone. Read in the list's body instead, every row change would be the list's change —
//  the whole-transcript republish `TranscriptWindow.entries` exists to avoid. Until 2026-10-12 a
//  bubble got the same by observing its managed `Message`.
//

import SwiftUI

struct ObservedTranscriptRow<Content: View>: View {
    let entry: TranscriptEntry
    @ViewBuilder let content: (TranscriptRow) -> Content

    var body: some View {
        content(entry.row)
    }
}
