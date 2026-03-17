//
//  QuoteSelectionSheet.swift
//  Construct Messenger
//
//  Allows the user to select a portion of a text message to use as a quote
//  when composing a reply.  Opens as a sheet from ChatView when the user
//  taps "Quote & Reply" in the context menu.

import SwiftUI
import UIKit

struct QuoteSelectionSheet: View {
    let message: Message
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedText: String = ""

    private var fullText: String { message.decryptedContent ?? "" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("quote_selection_hint", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                SelectableTextView(text: fullText, selectedText: $selectedText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                if !selectedText.isEmpty {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 3)
                        Text(selectedText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)
            .navigationTitle(NSLocalizedString("select_quote", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("cancel", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("reply_with_selection", comment: "")) {
                        onConfirm(selectedText.isEmpty ? fullText : selectedText)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Selectable UITextView Representable

struct SelectableTextView: UIViewRepresentable {
    let text: String
    @Binding var selectedText: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.text = text
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableTextView
        init(_ parent: SelectableTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ textView: UITextView) {
            let range = textView.selectedRange
            if range.length > 0, let swiftRange = Range(range, in: textView.text) {
                parent.selectedText = String(textView.text[swiftRange])
            } else {
                parent.selectedText = ""
            }
        }
    }
}
