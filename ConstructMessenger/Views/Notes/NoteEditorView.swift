//
//  NoteEditorView.swift
//  Construct Messenger
//
//  Writing a note, or the words of one (todo 279).
//

import SwiftUI

struct NoteEditorView: View {
    @State private var text: String
    /// True once stored; until then the sheet stays, with what was typed.
    let save: (String) -> Bool

    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(text: String = "", save: @escaping (String) -> Bool) {
        _text = State(initialValue: text)
        self.save = save
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        TextEditor(text: $text)
            .focused($isFocused)
            .font(CTFont.message(ChatUIConstants.Typography.messageTextSize))
            .foregroundStyle(Color.CT.text)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, CTLayout.edgePad)
            .ctBackground()
            .screenTitle(NSLocalizedString("notes_note", comment: ""))
            .accessibilityIdentifier(A11y.Notes.editor)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("save", comment: "")) { if save(text) { dismiss() } }
                        .disabled(!canSave)
                        .accessibilityIdentifier(A11y.Notes.save)
                }
            }
            .onAppear { isFocused = true }
    }
}
