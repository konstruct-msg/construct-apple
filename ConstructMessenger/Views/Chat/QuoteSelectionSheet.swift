//
//  QuoteSelectionSheet.swift
//  Construct Messenger
//
//  Allows the user to select a portion of a text message to use as a quote
//  when composing a reply.  Opens as a sheet from ChatView when the user
//  taps "Quote & Reply" in the context menu.

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct QuoteSelectionSheet: View {
    let message: Message
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedText: String = ""

    private var fullText: String { message.displayText }

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("select_quote", comment: ""),
                showBack: false,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                Button(NSLocalizedString("reply_with_selection", comment: "")) {
                    guard !selectedText.isEmpty else { return }
                    onConfirm(selectedText)
                    dismiss()
                }
                .font(CTFont.bold(13))
                .foregroundColor(selectedText.isEmpty ? Color.CT.textDim : Color.CT.accent)
                .disabled(selectedText.isEmpty)
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("quote_selection_hint", comment: ""))
                    .font(CTFont.regular(12))
                    .foregroundColor(Color.CT.textDim)
                    .padding(.horizontal)

                SelectableTextView(text: fullText, selectedText: $selectedText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.CT.bgMsg)
                    .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
                    .padding(.horizontal)

                if !selectedText.isEmpty {
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(Color.CT.accent)
                            .frame(width: 2)
                        Text(selectedText)
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                            .lineLimit(2)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.CT.bgMsg)
                    .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
                    .padding(.horizontal)
                }
            }
            .padding(.top, 8)

            HStack {
                Button(NSLocalizedString("cancel", comment: "")) { dismiss() }
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
            .ctBorderTop()
        }
        .background(Color.CT.bg)
    }
}

// MARK: - Selectable text view (platform-adaptive)

#if canImport(UIKit)
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

#elseif canImport(AppKit)

struct SelectableTextView: NSViewRepresentable {
    let text: String
    @Binding var selectedText: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let tv = scrollView.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.string = text
        tv.font = NSFont.preferredFont(forTextStyle: .body)
        tv.textContainerInset = NSSize(width: 8, height: 12)
        tv.backgroundColor = .clear
        tv.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        init(_ parent: SelectableTextView) { self.parent = parent }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let range = tv.selectedRange()
            if range.length > 0, let swiftRange = Range(range, in: tv.string) {
                parent.selectedText = String(tv.string[swiftRange])
            } else {
                parent.selectedText = ""
            }
        }
    }
}
#endif
