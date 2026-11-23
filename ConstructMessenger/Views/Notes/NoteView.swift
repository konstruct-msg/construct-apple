//
//  NoteView.swift
//  Construct Messenger
//
//  One note (todo 279): what it says and holds, drawn by the message bubbles' own views; edit,
//  copy, send to a chat, delete.
//

import SwiftUI

struct NoteView: View {
    @State private var note: Note
    let model: NotesModel

    @State private var isEditing = false
    @State private var deleting: Note?
    @State private var viewerStart: GalleryStartItem?
    #if os(iOS)
    @State private var isPickingChat = false
    @Environment(ChatsViewModel.self) private var chatsViewModel
    #endif
    @Environment(\.dismiss) private var dismiss

    init(note: Note, model: NotesModel) {
        _note = State(initialValue: note)
        self.model = model
    }

    private var row: TranscriptRow { TranscriptRow(note: note) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CTSpace.m) {
                Text(NoteSummary.origin(note))
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTSpace.m)
        }
        .ctBackground()
        .screenTitle(NSLocalizedString("notes_note", comment: ""))
        .toolbar { toolbar }
        .sheet(isPresented: $isEditing) {
            NoteEditorView(text: note.plainText ?? "") { text in
                guard model.edit(note, text: text) else { return false }
                if let edited = model.note(note.id) { note = edited }
                return true
            }
            .sheetNavigation()
        }
        .noteDeletion($deleting) { doomed in
            model.delete(doomed)
            dismiss()
        }
        #if os(iOS)
        .sheet(isPresented: $isPickingChat) {
            ForwardPickerView(onPick: send(to:)).sheetNavigation()
        }
        .fullScreenCover(item: $viewerStart) { viewer($0) }
        #else
        .sheet(item: $viewerStart) { viewer($0) }
        #endif
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if note.plainText != nil {
            ToolbarItem(placement: .primaryAction) {
                Button { isEditing = true } label: {
                    Label(NSLocalizedString("edit_message", comment: ""), systemImage: "pencil")
                }
                .accessibilityIdentifier(A11y.Notes.edit)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                #if os(iOS)
                Button { isPickingChat = true } label: {
                    Label(NSLocalizedString("notes_send", comment: ""), systemImage: "arrowshape.turn.up.right")
                }
                #endif
                if !note.readableText.isEmpty {
                    Button { PlatformClipboard.copy(note.readableText) } label: {
                        Label(NSLocalizedString("copy", comment: ""), systemImage: "doc.on.doc")
                    }
                    ShareLink(item: note.readableText) {
                        Label(NSLocalizedString("share", comment: ""), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    model.togglePin(note)
                    if let changed = model.note(note.id) { note = changed }
                } label: {
                    note.isPinned
                        ? Label(NSLocalizedString("notes_unpin", comment: ""), systemImage: "pin.slash")
                        : Label(NSLocalizedString("notes_pin", comment: ""), systemImage: "pin")
                }
                Button(role: .destructive) { deleting = note } label: {
                    Label(NSLocalizedString("delete", comment: ""), systemImage: "trash")
                }
            } label: {
                Label(NSLocalizedString("actions", comment: ""), systemImage: "ellipsis")
            }
            .accessibilityIdentifier(A11y.Notes.actions)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let row = row
        if let sticker = row.stickerReference {
            StickerBubbleView(reference: sticker, isSelected: false)
        } else if let media = MessageBubbleContentParsing.parseMediaMessage(row.legacyBody) {
            MediaMessageView(mediaContent: media, message: row, isSelected: false) { item in
                viewerStart = GalleryStartItem(id: row.id, itemIndex: item)
            }
        } else if let files = MessageBubbleContentParsing.parseFileMessage(row.legacyBody) {
            FileAttachmentBubbleView(fileContent: files, isSentByMe: true)
            words(files.caption)
        } else if let voice = MessageBubbleContentParsing.parseVoiceMessage(row.legacyBody) {
            VoiceMessageBubbleView(
                voiceContent: voice, isSentByMe: true, deliveryStatus: .delivered, onRetry: nil
            )
        } else {
            words(row.readableText)
        }
    }

    @ViewBuilder
    private func words(_ text: String) -> some View {
        if !text.isEmpty {
            LinkDetectingText(text, color: Color.CT.text)
                .font(CTFont.message(ChatUIConstants.Typography.messageTextSize))
                .textSelection(.enabled)
        }
    }

    private func viewer(_ start: GalleryStartItem) -> some View {
        MediaGalleryViewer(
            messages: [row],
            initialMessageId: start.messageId,
            initialItemIndex: start.itemIndex,
            isPresented: Binding(get: { viewerStart != nil }, set: { if !$0 { viewerStart = nil } })
        )
    }

    #if os(iOS)
    /// The picked chat sends it as its own message, as it sends a forward: nothing of the note —
    /// whose words they were, when — goes with it.
    private func send(to chat: ChatRecord) {
        guard let item = note.content else { return }
        ForwardDrafts.shared.hand([item], to: chat.id)
        chatsViewModel.selectedTab = 0
        chatsViewModel.chatToOpen = chat.id
    }
    #endif
}
