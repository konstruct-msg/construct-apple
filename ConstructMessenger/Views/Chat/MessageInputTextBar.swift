//
//  MessageInputTextBar.swift
//  Construct Messenger
//
//  The rounded input pill: text field, character counter, send button, voice button.
//  iOS: voice button appears when the field is empty.
//  macOS: TextEditor + send button only (Enter sends, Shift+Enter = new line).
//

import SwiftUI
import Combine

struct MessageInputTextBar: View {
    @Binding var text: String
    let canSend: Bool
    let isSending: Bool
    let onSend: () -> Void
    let onStartVoice: (() -> Void)?     // nil on macOS

    @FocusState private var focused: Bool

    /// Matches the attach `plus.circle` control (``CTLayout.controlHeight`` + pill).
    private static let controlSize: CGFloat = ChatUIConstants.InputBar.height
    private static let trailingIconSize: CGFloat = ChatUIConstants.InputBar.trailingIconSize

    var body: some View {
        // Center trailing controls with the single-line text row. Multi-line growth
        // keeps send/mic vertically centered in the capsule (not bottom-hanging).
        HStack(alignment: .center, spacing: 0) {
            textField
            charCounter
            sendButton
            voiceButton
        }
        .frame(minHeight: Self.controlSize)
        .fixedSize(horizontal: false, vertical: true)
        .glassCapsule()
    }

    // MARK: - Text field

    @ViewBuilder
    private var textField: some View {
        TextField(LocalizedStringKey("message_placeholder"), text: $text, axis: .vertical)
            #if os(macOS)
            .font(CTFont.regular(ChatUIConstants.Typography.macOSmessageTextSize))
            #else
            .font(CTFont.regular(ChatUIConstants.Typography.iOSmessageTextSize))
            #endif
            .foregroundColor(Color.CT.text)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .focused($focused)
            .padding(.leading, ChatUIConstants.InputBar.textLeadingPad)
            .padding(.trailing, canSend ? ChatUIConstants.Bubble.tightVerticalPadding : CTLayout.inlinePad)
            // Vertical padding keeps single-line height ≈ attach circle (controlHeight).
            .padding(.vertical, ChatUIConstants.InputBar.textVerticalPad)
            #if os(macOS)
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard !press.modifiers.contains(.shift) else { return .ignored }
                if canSend { onSend() }
                return .handled
            }
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
                    .font(.system(size: Self.trailingIconSize, weight: .regular))
                    .foregroundColor(Color.CT.accent)
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .contentShape(Circle())
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
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .contentShape(Circle())
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
