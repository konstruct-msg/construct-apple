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
    /// The mic ↔ camera switch, drawn over the whole bar: the capsule clips its contents, and
    /// the switch stands above it.
    @State private var micSwitch: MicModeButton.Mode?? = nil

    /// Matches the attach `plus.circle` control (``CTLayout.controlHeight`` + pill).
    private static let controlSize: CGFloat = ChatUIConstants.InputBar.height

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
        .overlay(alignment: .bottomTrailing) {
            if let choice = micSwitch {
                MicModeSwitch(choice: choice, width: Self.controlSize)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: micSwitch != nil)
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
                    .font(CTIcon.font(CTIcon.overlay, weight: .regular))
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
            MicModeButton(size: Self.controlSize, open: $micSwitch, onVoice: onStartVoice, onVideoNote: onStartVideoNote)
                .accessibilityIdentifier(A11y.Chat.voice)
                .transition(.scale.combined(with: .opacity))
        } else if !canSend, let onStartVoice {
            Button(action: onStartVoice) {
                Image(systemName: "mic.fill")
                    .font(CTIcon.font(CTIcon.nav, weight: .regular))
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
/// has. Held, it opens a two-segment switch above it — camera over mic, the mic under the
/// finger — and the finger, without lifting, slides up to the camera; releasing on a segment
/// starts that recording, releasing away from the switch starts nothing.
///
/// Both choices are on screen at the moment of choosing and nothing is remembered between
/// presses: a tap is always the voice message, so the camera never comes on unasked.
/// `decisions/video-notes-are-uncropped-and-expand.md`.
struct MicModeButton: View {
    enum Mode { case voice, videoNote }

    let size: CGFloat
    /// nil: closed. `.some(choice)`: open, with the segment under the finger (nil when it has
    /// left the switch). The bar draws the switch from this.
    @Binding var open: Mode??
    let onVoice: () -> Void
    let onVideoNote: () -> Void

    @State private var pressTask: Task<Void, Never>?

    private static let segment = ChatUIConstants.VideoNote.switchSegmentLength
    private static let margin = ChatUIConstants.VideoNote.switchCancelMargin

    var body: some View {
        Image(systemName: "mic.fill")
            .font(CTIcon.font(CTIcon.nav, weight: .regular))
            .foregroundColor(Color.CT.textDim)
            .opacity(open != nil ? 0 : 1)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { pressChanged(at: $0.location) }
                    .onEnded { pressEnded(at: $0.location) }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: open != nil) { _, isOpen in isOpen }
            .sensoryFeedback(.selection, trigger: open ?? nil) { old, new in old != nil && new != nil }
            .accessibilityElement()
            .accessibilityLabel(Text(LocalizedStringKey("voice_message")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onVoice() }
            .accessibilityAction(named: Text(LocalizedStringKey("video_note_record"))) { onVideoNote() }
    }

    /// Which segment is under `point` (the button's own coordinates; the switch grows upwards
    /// from the button's bottom edge, the mic segment over the button), or nil when the finger
    /// has left it.
    static func mode(at point: CGPoint, buttonSize size: CGFloat) -> Mode? {
        let bottom = size, top = size - 2 * segment
        guard point.y > top - margin, point.y < bottom + margin,
              point.x > -margin, point.x < size + margin else { return nil }
        return point.y < bottom - segment ? .videoNote : .voice
    }

    private func pressChanged(at point: CGPoint) {
        if open != nil {
            open = .some(Self.mode(at: point, buttonSize: size))
        } else if pressTask == nil {
            pressTask = Task { @MainActor in
                try? await Task.sleep(for: ChatUIConstants.VideoNote.switchPressDelay)
                guard !Task.isCancelled else { return }
                open = .some(.voice)
            }
        }
    }

    private func pressEnded(at point: CGPoint) {
        pressTask?.cancel()
        pressTask = nil
        guard open != nil else {
            onVoice()
            return
        }
        open = nil
        switch Self.mode(at: point, buttonSize: size) {
        case .voice: onVoice()
        case .videoNote: onVideoNote()
        case nil: break
        }
    }
}

/// The open switch: camera over mic, `width` wide, its bottom on the mic button's.
struct MicModeSwitch: View {
    let choice: MicModeButton.Mode?
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            segment(.videoNote, symbol: "video.fill", label: "video_note")
            segment(.voice, symbol: "mic.fill", label: "voice_message")
        }
        .frame(width: width)
        .background(.regularMaterial, in: Capsule())
    }

    private func segment(_ mode: MicModeButton.Mode, symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(CTIcon.font(CTIcon.nav, weight: .regular))
            .foregroundStyle(choice == mode ? Color.CT.bg : Color.CT.textDim)
            .frame(width: width, height: ChatUIConstants.VideoNote.switchSegmentLength)
            .background {
                if choice == mode { Capsule().fill(Color.CT.accent).padding(2) }
            }
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }
}
