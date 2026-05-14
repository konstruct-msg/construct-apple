//
//  MessageInputTextBar.swift
//  Construct Messenger
//
//  The rounded input pill: text field, character counter, send button, voice button.
//  iOS: voice button appears when the field is empty.
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
        HStack(alignment: .bottom, spacing: 0) {
            textField
            charCounter
            sendButton
            voiceButton
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.CT.outMsgBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.CT.noise, lineWidth: 0.5))
    }

    // MARK: - Text field

    @ViewBuilder
    private var textField: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(LocalizedStringKey("message_placeholder"))
                    .foregroundStyle(Color.CT.textDim)
                    .font(CTFont.regular(13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.text)
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
            .font(CTFont.regular(14))
            .foregroundColor(Color.CT.text)
            .lineLimit(1...5)
            .padding(.leading, 12)
            .padding(.trailing, canSend ? 8 : 12)
            .padding(.vertical, 10)
            .focused($focused)
        #endif
    }

    // MARK: - Character counter

    @ViewBuilder
    private var charCounter: some View {
        let remaining = MessageSizeLimits.maxTextCharacters - text.count
        if remaining < 200 {
            if remaining < 0 {
                // Oversized: will auto-split — show chunk count
                let chunks = MessageValidator.splitIntoChunks(text)
                Text("→ \(chunks.count) msgs")
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.accent)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            } else {
                Text("\(remaining)")
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.textDim)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Send button

    @ViewBuilder
    private var sendButton: some View {
        if canSend {
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(Color.CT.accent)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
                    #if os(macOS)
                    .help("Send (⏎) · New line (⇧⏎)")
                    #endif
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Voice button (shown when input is empty and voice is available)

    @ViewBuilder
    private var voiceButton: some View {
        if !canSend, let onStartVoice {
            Button(action: onStartVoice) {
                Image(systemName: "mic.fill")
                    .font(.system(size: CTLayout.navIconSize))
                    .foregroundColor(Color.CT.textDim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        }
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
    .background(Color.platformBackground)
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
    .background(Color.platformBackground)
}
