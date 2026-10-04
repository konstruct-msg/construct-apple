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
    let sendOnReturn: Bool
    let onSend: () -> Void
    let onStartVoice: (() -> Void)?     // nil on macOS
    /// A long press on the mic offers the camera; nil leaves the mic a plain button.
    let onStartVideoNote: (() -> Void)?

    @FocusState private var focused: Bool

    /// Matches the attach `plus.circle` control (``CTLayout.controlHeight`` + pill).
    private static let controlSize: CGFloat = ChatUIConstants.InputBar.height
    private static let trailingIconSize: CGFloat = ChatUIConstants.InputBar.trailingIconSize

    init(
        text: Binding<String>,
        canSend: Bool,
        sendOnReturn: Bool = true,
        onSend: @escaping () -> Void,
        onStartVoice: (() -> Void)? = nil,
        onStartVideoNote: (() -> Void)? = nil
    ) {
        self._text = text
        self.canSend = canSend
        self.sendOnReturn = sendOnReturn
        self.onSend = onSend
        self.onStartVoice = onStartVoice
        self.onStartVideoNote = onStartVideoNote
    }

    var body: some View {
        // Center trailing controls with the single-line text row. Multi-line growth
        // keeps send/mic vertically centered (not bottom-hanging).
        HStack(alignment: .center, spacing: 0) {
            textField
            charCounter
            sendButton
            voiceButton
        }
        .frame(minHeight: Self.controlSize)
        .fixedSize(horizontal: false, vertical: true)
        // Fixed radius (half of controlHeight): stadium when 1-line, soft rect when
        // multi-line — same family, no pill↔control jump on height change.
        .glassCapsule(cornerRadius: ChatUIConstants.InputBar.cornerRadius)
    }

    // MARK: - Text field

    @ViewBuilder
    private var textField: some View {
        TextField(LocalizedStringKey("message_placeholder"), text: $text, axis: .vertical)
            #if os(macOS)
            .font(CTFont.message(ChatUIConstants.Typography.macOSmessageTextSize))
            #else
            .font(CTFont.message(ChatUIConstants.Typography.iOSmessageTextSize))
            #endif
            .foregroundColor(Color.CT.text)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .focused($focused)
            // Diagnostic only (no-op outside DEBUG): says whether SwiftUI believes the field still
            // has focus when the keyboard disappears at the start of a voice recording.
            .onChange(of: focused) { _, isFocused in
                KeyboardEventTracer.shared.noteFocus(isFocused)
            }
            .accessibilityIdentifier(A11y.Chat.input)
            .padding(.leading, ChatUIConstants.InputBar.textLeadingPad)
            .padding(.trailing, canSend ? ChatUIConstants.Bubble.tightVerticalPadding : CTLayout.inlinePad)
            // Vertical padding keeps single-line height ≈ attach circle (controlHeight).
            .padding(.vertical, ChatUIConstants.InputBar.textVerticalPad)
            #if os(macOS)
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard sendOnReturn else { return .ignored }
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
                Text(String(format: NSLocalizedString("composer_split_count", comment: ""), chunks.count))
                    .font(CTFont.ui(10, relativeTo: .caption2))
                    .foregroundStyle(Color.CT.accent)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            } else {
                Text("\(remaining)")
                    .font(CTFont.micro)
                    .foregroundColor(Color.CT.textDim)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Send button

    /// Always live while there is something to send. It used to be disabled for the whole
    /// duration of an in-flight send — which on a media send is the entire upload, so the
    /// composer went dead for minutes with nothing on screen explaining why. Send progress
    /// belongs on the message: the upload placeholder shows a percentage badge and the
    /// bubble carries its delivery status. Concurrent sends are safe — each one owns its
    /// message id and its own task.
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
                    .help(NSLocalizedString(sendOnReturn ? "send_on_enter_help" : "send_action", comment: ""))
                    #endif
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Chat.send)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Voice button (shown when input is empty and voice is available)

    @ViewBuilder
    private var voiceButton: some View {
        if !canSend, let onStartVoice, let onStartVideoNote {
            MicModeButton(size: Self.controlSize, onVoice: onStartVoice, onVideoNote: onStartVideoNote)
                .accessibilityIdentifier(A11y.Chat.voice)
                .transition(.scale.combined(with: .opacity))
        } else if !canSend, let onStartVoice {
            Button(action: onStartVoice) {
                Image(systemName: "mic.fill")
                    .font(.system(size: CTLayout.navIconSize))
                    .foregroundColor(Color.CT.textDim)
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Chat.voice)
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
            onSend: {},
            onStartVoice: {},
            onStartVideoNote: {}
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
            onSend: {},
            onStartVoice: {}
        )
        .padding(.horizontal)
    }
    .background(Color.platformBackground)
}

// MARK: - Mic ↔ camera

/// The mic button, which also offers the camera. A tap records a voice message, as it always
/// has. Held, it opens a two-segment switch — camera | mic, the mic under the finger — and the
/// finger, without lifting, slides to the one it wants; releasing on a segment starts that
/// recording, releasing away from the switch starts nothing.
///
/// Both choices are on screen at the moment of choosing and nothing is remembered between
/// presses: a tap is always the voice message, so the camera never comes on unasked.
/// `decisions/video-notes-are-uncropped-and-expand.md`.
struct MicModeButton: View {
    enum Mode { case voice, videoNote }

    let size: CGFloat
    let onVoice: () -> Void
    let onVideoNote: () -> Void

    @State private var pressTask: Task<Void, Never>?
    @State private var isOpen = false
    @State private var choice: Mode?

    private static let segment = ChatUIConstants.VideoNote.switchSegmentWidth
    private static let margin = ChatUIConstants.VideoNote.switchCancelMargin

    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: CTLayout.navIconSize))
            .foregroundColor(Color.CT.textDim)
            .opacity(isOpen ? 0 : 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .overlay(alignment: .trailing) {
                if isOpen { modeSwitch.allowsHitTesting(false).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing))) }
            }
            .animation(.easeOut(duration: 0.15), value: isOpen)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { pressChanged(at: $0.location) }
                    .onEnded { pressEnded(at: $0.location) }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: isOpen) { _, open in open }
            .sensoryFeedback(.selection, trigger: choice) { old, new in old != nil && new != nil }
            .accessibilityElement()
            .accessibilityLabel(Text(LocalizedStringKey("voice_message")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onVoice() }
            .accessibilityAction(named: Text(LocalizedStringKey("video_note_record"))) { onVideoNote() }
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            segment(.videoNote, symbol: "video.fill", label: "video_note")
            segment(.voice, symbol: "mic.fill", label: "voice_message")
        }
        .frame(height: size)
        .background(.regularMaterial, in: Capsule())
    }

    private func segment(_ mode: Mode, symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: CTLayout.navIconSize))
            .foregroundStyle(choice == mode ? Color.CT.bg : Color.CT.textDim)
            .frame(width: Self.segment, height: size)
            .background {
                if choice == mode { Capsule().fill(Color.CT.accent).padding(2) }
            }
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }

    /// Which segment is under `point` (the button's own coordinates; the switch grows leftwards
    /// from its trailing edge), or nil when the finger has left it.
    static func mode(at point: CGPoint, buttonSize size: CGFloat) -> Mode? {
        let right = size, left = size - 2 * segment
        guard point.x > left - margin, point.x < right + margin,
              point.y > -margin, point.y < size + margin else { return nil }
        return point.x < right - segment ? .videoNote : .voice
    }

    private func mode(at point: CGPoint) -> Mode? { Self.mode(at: point, buttonSize: size) }

    private func pressChanged(at point: CGPoint) {
        if isOpen {
            choice = mode(at: point)
        } else if pressTask == nil {
            pressTask = Task { @MainActor in
                try? await Task.sleep(for: ChatUIConstants.VideoNote.switchPressDelay)
                guard !Task.isCancelled else { return }
                choice = .voice
                isOpen = true
            }
        }
    }

    private func pressEnded(at point: CGPoint) {
        pressTask?.cancel()
        pressTask = nil
        guard isOpen else {
            onVoice()
            return
        }
        isOpen = false
        let chosen = mode(at: point)
        choice = nil
        switch chosen {
        case .voice: onVoice()
        case .videoNote: onVideoNote()
        case nil: break
        }
    }
}
