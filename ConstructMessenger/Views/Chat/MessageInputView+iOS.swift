//
//  MessageInputView+iOS.swift
//  Construct Messenger
//
//  iOS chat composer implementation: action-sheet attachments, camera capture,
//  photo picker, file picker, and voice recording/preview states.
//

import SwiftUI
import PhotosUI
#if os(iOS)
import UIKit
#endif

struct IOSMessageInputView: View {
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
    @State private var showCameraPicker = false
    @StateObject private var audioRecorder = AudioRecorderService.shared
    @StateObject private var attachments = MessageInputAttachmentStore()
    @State private var showMicPermissionAlert = false
    /// Per-user preference: send photos at original quality (no recompression).
    @AppStorage("composer.sendOriginalPhotos") private var sendOriginal = false

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
            if case .success(let urls) = result { attachments.handlePickedFiles(urls) }
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
                onRemove: removePhoto
            )
            qualityToggle
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

    /// Compress / original-quality toggle, shown above the composer when photos are attached.
    private var qualityToggle: some View {
        Button { sendOriginal.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: sendOriginal ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                Text(LocalizedStringKey("send_original_quality"))
                    .font(CTFont.regular(12))
            }
            .foregroundColor(sendOriginal ? Color.CT.accent : Color.CT.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            attachmentButton
            MessageInputTextBar(
                text: $text,
                canSend: canSend,
                isSending: isSending,
                onSend: sendMessage,
                onStartVoice: startVoiceRecording
            )
        }
        // No collective capsule — they are separate floating glass elements now
        .padding(.horizontal, 4)
    }

    private var attachmentButton: some View {
        Button { showAttachmentMenu = true } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 20))
                .foregroundColor(Color.CT.textDim)
                .frame(width: 44, height: 44)
                .glassCapsule(cornerRadius: 999)
        }
        .buttonStyle(.plain)
        .confirmationDialog(LocalizedStringKey("attach"), isPresented: $showAttachmentMenu) {
            Button { showPhotoPicker = true } label: {
                Label(LocalizedStringKey("photos"), systemImage: "photo.on.rectangle")
            }
            Button(LocalizedStringKey("camera")) { showCameraPicker = true }
            Button(LocalizedStringKey("files")) { showFilePicker = true }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 99, matching: .images)
        .sheet(isPresented: $showCameraPicker) {
            CameraPickerView { image in
                attachments.appendDroppedImages([image])
            }
            .ignoresSafeArea()
        }
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
        let quality: MediaQuality = sendOriginal ? .original : .compressed
        let preparedAttachments = attachments.selectedAttachments.map { att -> MediaAttachment in
            var a = att; a.quality = quality; return a
        }
        onSend(preparedAttachments, attachments.selectedFileURLs)
        selectedPhotos.removeAll()
        attachments.clear()
    }

    private func removePhoto(at index: Int) {
        attachments.removeAttachment(at: index)
        if index < selectedPhotos.count { selectedPhotos.remove(at: index) }
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
