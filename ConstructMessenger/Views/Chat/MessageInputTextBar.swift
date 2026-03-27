//
//  MessageInputTextBar.swift
//  Construct Messenger
//
//  The rounded input pill: text field, character counter, send button, voice button.
//  iOS: voice (🎙) button appears when the field is empty.
//  macOS: TextEditor + send button only (Enter sends, Shift+Enter = new line).
//

import SwiftUI

struct MessageInputTextBar: View {
    @Binding var text: String
    let canSend: Bool
    let isSending: Bool
    let onSend: () -> Void
    let onStartVoice: (() -> Void)?     // nil on macOS

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            textField
            charCounter
            sendButton
            voiceButton
        }
        #if canImport(UIKit)
        .background(Color(uiColor: .systemGray6))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Text field

    @ViewBuilder
    private var textField: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(LocalizedStringKey("message_placeholder"))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    if canSend { onSend() }
                    return .handled
                }
        }
        .frame(minHeight: 36, maxHeight: 120)
        .padding(.trailing, canSend ? 8 : 12)
        #else
        TextField("message_placeholder", text: $text, axis: .vertical)
            .lineLimit(1...5)
            .padding(.leading, 12)
            .padding(.trailing, canSend ? 8 : 12)
            .padding(.vertical, 8)
            .focused($focused)
        #endif
    }

    // MARK: - Character counter

    @ViewBuilder
    private var charCounter: some View {
        if text.count > MessageSizeLimits.maxTextCharacters - 200 {
            let remaining = MessageSizeLimits.maxTextCharacters - text.count
            Text(remaining >= 0 ? "\(remaining)" : "\(-remaining) over limit")
                .font(.caption2)
                .foregroundColor(remaining < 0 ? .red : .secondary)
                .padding(.trailing, 4)
                .transition(.opacity)
        }
    }

    // MARK: - Send button

    @ViewBuilder
    private var sendButton: some View {
        if canSend {
            Button(action: onSend) {
                #if os(macOS)
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 26, height: 26)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 6)
                .help("Send (⏎) · New line (⇧⏎)")
                #else
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(Color.blue)
                    .padding(.trailing, 4)
                #endif
            }
            .disabled(isSending)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Voice button (iOS only, shown when input is empty)

    @ViewBuilder
    private var voiceButton: some View {
        #if os(iOS)
        if !canSend, let onStartVoice {
            Button(action: onStartVoice) {
                Image(systemName: "microphone")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.secondary)
                    .padding(.trailing, 6)
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
        #endif
    }
}

// MARK: - Preview

#Preview("Input bar — empty") {
    VStack {
        Spacer()
        MessageInputTextBar(
            text: .constant(""),
            canSend: false,
            isSending: false,
            onSend: {},
            onStartVoice: {}
        )
        .padding(.horizontal)
    }
    .background(Color(.systemBackground))
}

#Preview("Input bar — text") {
    VStack {
        Spacer()
        MessageInputTextBar(
            text: .constant("Hello there!"),
            canSend: true,
            isSending: false,
            onSend: {},
            onStartVoice: {}
        )
        .padding(.horizontal)
    }
    .background(Color(.systemBackground))
}
