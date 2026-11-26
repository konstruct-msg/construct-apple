//
//  NotesRowView.swift
//  Construct Messenger
//
//  The Notes row of the chat list (`ChatsListEntry.notes`), laid out as a chat row: a mark where
//  the avatar is, "Notes", the newest note's first line and its time.
//

import SwiftUI

struct NotesRowView: View {
    let newest: Note?
    var isSelected: Bool = false

    private var dimStyle: Color { isSelected ? Color.CT.text.opacity(0.75) : Color.CT.textDim }

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            ZStack {
                // Plain, not a person's avatar: the hexagon draws a pattern under the mark.
                Circle()
                    .fill(Color.CT.accentDim)
                    .frame(width: CTAvatarSize.row, height: CTAvatarSize.row)
                Image(systemName: "note.text")
                    .font(CTIcon.font(CTIcon.row, weight: .semibold))
                    .foregroundStyle(Color.CT.text)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: CTSpace.xs) {
                HStack(alignment: .firstTextBaseline, spacing: CTLayout.inlinePad) {
                    Text(LocalizedStringKey("notes_title"))
                        .font(CTFont.bodyEmphasis)
                        .foregroundColor(Color.CT.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let newest {
                        Text(ChatRowView.rowTimestampText(newest.createdAt))
                            .font(CTFont.caption)
                            .foregroundStyle(dimStyle)
                            .lineLimit(1)
                    }
                }
                Text(preview)
                    .typesetting(asScriptOf: preview)
                    .font(CTFont.secondary)
                    .foregroundStyle(dimStyle)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, CTLayout.inlinePad)
        .contentShape(Rectangle())
    }

    /// The newest note's first line; with no note, what Notes are.
    private var preview: String {
        guard let newest else { return NSLocalizedString("notes_stay_here", comment: "") }
        let firstLine = newest.readableText
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return Chat.formatPreviewText(firstLine.isEmpty ? NSLocalizedString("notes_note", comment: "") : firstLine)
    }
}
