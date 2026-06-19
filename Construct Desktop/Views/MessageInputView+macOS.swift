//
//  MessageInputView+macOS.swift
//  Construct Messenger
//
//  Shared macOS chat composer used by both the standalone desktop app and
//  any shared macOS chat surfaces in the main target.
//

#if os(macOS)
import SwiftUI
import PhotosUI
import Combine

struct DesktopMessageInputView: View {
    @Binding var text: String
    @Binding var droppedImages: [PlatformImage]
    let isSending: Bool
    let replyingTo: Message?
    let quoteOverride: String?
    let editingMessage: Message?
    let onSend: ([MediaAttachment], [URL]) -> Void
    var onSendVoice: ((URL, TimeInterval, [Float]) -> Void)? = nil
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @StateObject private var attachments = MessageInputAttachmentStore()
    @StateObject private var audioRecorder = AudioRecorderService.shared
    @State private var showMicPermissionAlert = false

    var body: some View {
        VStack(spacing: 0) {
            replyOrEditBars
            attachmentPreviews
            voiceOrInputRow
        }
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: replyingTo != nil)
        .animation(.easeInOut(duration: 0.2), value: editingMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: !attachments.selectedAttachments.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: audioRecorder.state)
        .alert(
            NSLocalizedString("mic_denied_title", comment: ""),
            isPresented: $showMicPermissionAlert
        ) {
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("open_settings", comment: "")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
        } message: {
            Text(NSLocalizedString("mic_denied_message_macos", comment: ""))
        }
        .onChange(of: selectedPhotos) {
            Task { await attachments.loadSelectedPhotos(selectedPhotos) }
        }
        .onChange(of: droppedImages) { _, newImages in
            attachments.appendDroppedImages(newImages)
            droppedImages.removeAll()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                attachments.handlePickedFiles(urls)
            }
        }
    }

    @ViewBuilder
    private var replyOrEditBars: some View {
        if let msg = replyingTo {
            MessageReplyBar(
                content: quoteOverride ?? (msg.displayText.isEmpty ? nil : msg.displayText),
                messageId: msg.id,
                onCancel: onCancelReply
            )
        }
        if let msg = editingMessage {
            MessageEditBar(content: msg.displayText, onCancel: onCancelEdit)
        }
    }

    @ViewBuilder
    private var attachmentPreviews: some View {
        if !attachments.selectedAttachments.isEmpty {
            MessagePhotoPreviewBar(
                images: attachments.selectedAttachments.compactMap { $0.displayImage },
                onRemove: attachments.removeAttachment
            )
        }
        if !attachments.selectedFileURLs.isEmpty {
            MessageFilePreviewBar(
                fileURLs: attachments.selectedFileURLs,
                onRemove: attachments.removeFile
            )
        }
    }

    @ViewBuilder
    private var voiceOrInputRow: some View {
        switch audioRecorder.state {
        case .recording(let duration, _):
            recordingRow(duration: duration)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .recorded(let url, let duration, let waveform):
            recordedRow(url: url, duration: duration, waveform: waveform)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
        case .idle:
            inputRow
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            MessageInputTextBar(
                text: $text,
                canSend: canSend,
                isSending: isSending,
                onSend: sendMessage,
                onStartVoice: startVoiceRecording
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var attachmentButton: some View {
        Button { showAttachmentMenu = true } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundColor(Color.CT.textDim)
        }
        .buttonStyle(.automatic)
        .controlSize(.extraLarge)
        .background(.ultraThinMaterial)
        .background(Color.CT.bg.opacity(0.7))
        .clipShape(Circle())
        .ctNoiseCircleBorder() // thin noise border on top of glass
        .shadow(color: Color.black.opacity(0.2), radius: 8, y: 2)
        .popover(isPresented: $showAttachmentMenu, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                popoverButton(label: "photos", icon: "photo.on.rectangle") {
                    showAttachmentMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showPhotoPicker = true }
                }
                Divider()
                popoverButton(label: "files", icon: "paperclip") {
                    showAttachmentMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { showFilePicker = true }
                }
            }
            .frame(width: 180)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: 99,
            matching: .images
        )
    }

    private func recordingRow(duration: TimeInterval) -> some View {
        HStack(spacing: 12) {
            Button { audioRecorder.cancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.CT.textDim)
            }
            .buttonStyle(.plain)

            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.CT.danger)

            Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.CT.danger)

            Spacer()

            Button { audioRecorder.stopRecording() } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.CT.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.CT.outMsgBg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.CT.noise, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func recordedRow(url: URL, duration: TimeInterval, waveform: [Float]) -> some View {
        HStack(spacing: 12) {
            Button { audioRecorder.cancel() } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.CT.danger)
            }
            .buttonStyle(.plain)

            Text(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.CT.textDim)

            Text(NSLocalizedString("voice_ready_to_send", comment: ""))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.CT.textDim)

            Spacer()

            Button {
                onSendVoice?(url, duration, waveform)
                audioRecorder.resetAfterSend()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.CT.outMsgBg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.CT.noise, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func popoverButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(label), systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var canSend: Bool {
        attachments.canSend(text: text)
    }

    private func startVoiceRecording() {
        Task {
            do {
                try await audioRecorder.startRecording()
            } catch AudioRecorderService.RecorderError.permissionDenied {
                showMicPermissionAlert = true
            } catch {
                Log.error("Recording failed: \(error)", category: "MessageInput")
            }
        }
    }

    private func sendMessage() {
        onSend(attachments.selectedAttachments, attachments.selectedFileURLs)
        selectedPhotos.removeAll()
        attachments.clear()
    }
}

#Preview("Desktop Input — idle") {
    @Previewable @State var text = ""
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        DesktopMessageInputView(
            text: $text,
            droppedImages: $dropped,
            isSending: false,
            replyingTo: nil,
            quoteOverride: nil,
            editingMessage: nil,
            onSend: { _, _ in },
            onCancelReply: {},
            onCancelEdit: {}
        )
    }
    .background(Color.CT.bg)
    .frame(width: 600, height: 200)
}

#Preview("Desktop Input — with text") {
    @Previewable @State var text = "Drafting a message..."
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        DesktopMessageInputView(
            text: $text,
            droppedImages: $dropped,
            isSending: false,
            replyingTo: nil,
            quoteOverride: nil,
            editingMessage: nil,
            onSend: { _, _ in },
            onCancelReply: {},
            onCancelEdit: {}
        )
    }
    .background(Color.CT.bg)
    .frame(width: 600, height: 200)
}
#endif
