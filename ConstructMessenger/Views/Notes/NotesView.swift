//
//  NotesView.swift
//  Construct Messenger
//
//  Settings → Notes (todo 279): a list, pinned first; search; a swipe pins or deletes.
//

import SwiftUI

struct NotesView: View {
    @State private var model = NotesModel()
    @State private var isWriting = false
    @State private var deleting: Note?

    var body: some View {
        List {
            ForEach(model.notes) { note in
                NavigationLink {
                    NoteView(note: note, model: model)
                } label: {
                    NoteListRow(note: note)
                }
                .listRowBackground(Color.CT.bg)
                .accessibilityIdentifier(A11y.Notes.row(note.id))
                .onAppear { model.loadMoreIfNeeded(after: note) }
                .swipeActions(edge: .leading) {
                    Button { model.togglePin(note) } label: { pinLabel(note) }
                        .tint(Color.CT.accent)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = note } label: {
                        Label(NSLocalizedString("delete", comment: ""), systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button { model.togglePin(note) } label: { pinLabel(note) }
                    if !note.readableText.isEmpty {
                        Button { PlatformClipboard.copy(note.readableText) } label: {
                            Label(NSLocalizedString("copy", comment: ""), systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) { deleting = note } label: {
                        Label(NSLocalizedString("delete", comment: ""), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .ctBackground()
        .searchable(text: $model.query, prompt: Text(LocalizedStringKey("search_prompt")))
        .overlay { if model.notes.isEmpty { emptyState } }
        .screenTitle(NSLocalizedString("notes_title", comment: ""))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isWriting = true } label: {
                    Label(NSLocalizedString("notes_new", comment: ""), systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier(A11y.Notes.new)
            }
        }
        .task { await model.follow() }
        .sheet(isPresented: $isWriting) {
            NoteEditorView { model.add($0) }.sheetNavigation()
        }
        .noteDeletion($deleting) { model.delete($0) }
    }

    private func pinLabel(_ note: Note) -> some View {
        note.isPinned
            ? Label(NSLocalizedString("notes_unpin", comment: ""), systemImage: "pin.slash")
            : Label(NSLocalizedString("notes_pin", comment: ""), systemImage: "pin")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isSearching {
            ContentUnavailableView.search(text: model.query)
        } else {
            ContentUnavailableView {
                Label {
                    Text(NSLocalizedString("notes_empty_title", comment: "")).font(CTFont.headline)
                } icon: {
                    Image(systemName: "note.text")
                }
            } description: {
                Text(NSLocalizedString("notes_stay_here", comment: "")).font(CTFont.body)
            }
        }
    }
}

/// Three lines of what it says, what it holds, whose it was or when it was written.
private struct NoteListRow: View {
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: CTSpace.m) {
            lead
            VStack(alignment: .leading, spacing: CTSpace.xs) {
                Text(NoteSummary.text(note))
                    .font(CTFont.message(15))
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(3)
                Text(NoteSummary.origin(note))
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
            }
            Spacer(minLength: .zero)
            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(CTFont.caption)
                    .foregroundStyle(Color.CT.accent)
                    .accessibilityLabel(NSLocalizedString("notes_pinned", comment: ""))
            }
        }
        .padding(.vertical, CTSpace.xs)
    }

    /// A picture's own tile — the album bubble's — or a symbol of what else it holds.
    @ViewBuilder
    private var lead: some View {
        switch NoteSummary.holds(note) {
        case .pictures:
            let row = TranscriptRow(note: note)
            if let media = MessageBubbleContentParsing.parseMediaMessage(row.legacyBody) {
                GridCell(
                    mediaContent: media, message: row, itemIndex: 0, isPlaceholder: false,
                    extraCount: 0, onTap: {}
                )
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                .clipShape(CTShape.control())
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(NSLocalizedString("photo", comment: ""))
            }
        case .some(let holds):
            Image(systemName: holds.symbol)
                .font(CTIcon.font(CTIcon.row, weight: .regular))
                .foregroundStyle(Color.CT.accent)
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                .accessibilityLabel(NSLocalizedString(holds.labelKey, comment: ""))
        case nil:
            EmptyView()
        }
    }
}

/// What the list says of a note, read from its body once per row.
enum NoteSummary {
    enum Holds: Equatable {
        case pictures, files, voice, sticker

        var symbol: String {
            switch self {
            case .pictures: "photo"
            case .files: "doc"
            case .voice: "waveform"
            case .sticker: "face.smiling"
            }
        }

        var labelKey: String {
            switch self {
            case .pictures: "photo"
            case .files: "file"
            case .voice: "voice_message"
            case .sticker: "sticker"
            }
        }
    }

    static func holds(_ note: Note) -> Holds? {
        switch note.content {
        case .media: return .pictures
        case .files: return .files
        case .voice: return .voice
        case .sticker: return .sticker
        case .text, nil: return nil
        }
    }

    /// The words; for files without any, their names.
    static func text(_ note: Note) -> String {
        let words = note.readableText
        if !words.isEmpty { return words }
        if case .files(let files, _) = note.content {
            let names = files.compactMap(\.filename).filter { !$0.isEmpty }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        guard let holds = holds(note) else { return "" }
        return NSLocalizedString(holds.labelKey, comment: "")
    }
}

extension NoteSummary {
    /// Whose message it was and when; for one's own words, when they were written.
    static func origin(_ note: Note) -> String {
        if let name = note.sourceName, let at = note.sourceAt {
            return String(format: NSLocalizedString("notes_from", comment: ""), name, stamp(at))
        }
        return stamp(note.editedAt ?? note.createdAt)
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension View {
    /// A note holds what may exist nowhere else: deleting one is asked about.
    func noteDeletion(_ note: Binding<Note?>, delete: @escaping (Note) -> Void) -> some View {
        confirmationDialog(
            NSLocalizedString("notes_delete_title", comment: ""),
            isPresented: Binding(get: { note.wrappedValue != nil }, set: { if !$0 { note.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: note.wrappedValue
        ) { doomed in
            Button(NSLocalizedString("delete", comment: ""), role: .destructive) { delete(doomed) }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        }
    }
}
