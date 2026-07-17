//
//  MessageInputView+iOS.swift
//  Construct Messenger
//
//  iOS chat composer implementation: action-sheet attachments, camera capture,
//  photo picker, file picker, and voice recording/preview states.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct IOSMessageInputView: View {
    private static let attachmentPreviewSpacing: CGFloat = 10

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

    @State private var showMediaPicker = false
    @StateObject private var audioRecorder = AudioRecorderService.shared
    @StateObject private var attachments = MessageInputAttachmentStore()
    @State private var showMicPermissionAlert = false

    var body: some View {
        VStack(spacing: 0) {
            replyOrEditBars
            attachmentPreviews
            voiceOrInputRow
                .padding(.top, hasAttachmentPreviews ? Self.attachmentPreviewSpacing : 0)
        }
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: replyingTo != nil)
        .animation(.easeInOut(duration: 0.2), value: editingMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: !attachments.selectedAttachments.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: audioRecorder.state)
        .alert("Microphone Access Denied", isPresented: $showMicPermissionAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("Please allow microphone access in Settings to send voice messages.")
        }
        .onChange(of: droppedImages) { _, newImages in
            attachments.appendDroppedImages(newImages)
            droppedImages.removeAll()
        }
        .sheet(isPresented: $showMediaPicker) {
            MediaPickerSheet(
                maxSelection: 99,
                onConfirm: { media in
                    // Confirm → composer strip (caption / send from input bar).
                    attachments.appendAttachments(media)
                },
                onPickFiles: { urls in
                    attachments.handlePickedFiles(urls)
                }
            )
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
        // Quality lives in the media picker (HD / video menu). Composer only shows thumbs.
        if !attachments.selectedAttachments.isEmpty {
            MessagePhotoPreviewBar(
                images: attachments.selectedAttachments.compactMap { $0.displayImage },
                onRemove: removePhoto
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
        case .recording(let duration, let waveform):
            VoiceRecordingBar(duration: duration, waveform: waveform) {
                audioRecorder.stopRecording()
            } onCancel: {
                audioRecorder.cancel()
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .padding(.vertical, 8)

        case .recorded(let url, let duration, let waveform):
            VoicePreviewBar(duration: duration, waveform: waveform) {
                onSendVoice?(url, duration, waveform)
                audioRecorder.resetAfterSend()
            } onDiscard: {
                audioRecorder.cancel()
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .padding(.vertical, 8)

        case .idle:
            inputRow
        }
    }

    private var inputRow: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            attachmentButton
            MessageInputTextBar(
                text: $text,
                canSend: canSend,
                isSending: isSending,
                onSend: sendMessage,
                onStartVoice: startVoiceRecording
            )
        }
        // No collective capsule — separate floating glass elements (same pill radius).
        .padding(.horizontal, 4)
    }

    private var attachmentButton: some View {
        Button { showMediaPicker = true } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: CTLayout.navIconSize))
                .foregroundColor(Color.CT.textDim)
                .frame(width: CTLayout.controlHeight, height: CTLayout.controlHeight)
                .glassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey("attach")))
    }

    private var canSend: Bool {
        attachments.canSend(text: text)
    }

    private var hasAttachmentPreviews: Bool {
        !attachments.selectedAttachments.isEmpty || !attachments.selectedFileURLs.isEmpty
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
        // Quality is stamped by the media picker (or camera/drop helpers below).
        // Do not batch-overwrite here — that used to fight the picker's HD / video menu.
        onSend(attachments.selectedAttachments, attachments.selectedFileURLs)
        attachments.clear()
    }

    private func removePhoto(at index: Int) {
        attachments.removeAttachment(at: index)
    }
}

struct CameraPickerView: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        init(onCapture: @escaping (UIImage) -> Void) { self.onCapture = onCapture }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            picker.dismiss(animated: true)
            if let img = image { onCapture(img) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

#Preview("Input") {
    @Previewable @State var text = ""
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        IOSMessageInputView(
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
    .background(Color.platformBackground)
}
