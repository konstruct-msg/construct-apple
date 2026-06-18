//
//  MessageInputView+iOS.swift
//  Construct Messenger
//
//  iOS chat composer implementation: action-sheet attachments, camera capture,
//  photo picker, file picker, and voice recording/preview states.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var selectedAttachments: [MediaAttachment] = []
    @State private var selectedFileURLs: [URL] = []
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showCameraPicker = false
    @StateObject private var audioRecorder = AudioRecorderService.shared
    @State private var showMicPermissionAlert = false
    /// Per-user preference: send photos at original quality (no recompression).
    @AppStorage("composer.sendOriginalPhotos") private var sendOriginal = false

    var body: some View {
        VStack(spacing: 0) {
            replyOrEditBars
            attachmentPreviews
            voiceOrInputRow
        }
        .background(Color.CT.bg)
        .ctBorderTop()
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: replyingTo != nil)
        .animation(.easeInOut(duration: 0.2), value: editingMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: !selectedAttachments.isEmpty)
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
            Task { await loadSelectedPhotos() }
        }
        .onChange(of: droppedImages) { _, newImages in
            guard !newImages.isEmpty else { return }
            selectedAttachments.append(contentsOf: newImages.map { MediaAttachment(image: $0) })
            droppedImages.removeAll()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { handlePickedFiles(urls) }
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
        if !selectedAttachments.isEmpty {
            MessagePhotoPreviewBar(images: selectedAttachments.compactMap { $0.displayImage }, onRemove: removePhoto)
            qualityToggle
        }
        if !selectedFileURLs.isEmpty {
            MessageFilePreviewBar(fileURLs: selectedFileURLs) { index in
                selectedFileURLs.remove(at: index)
            }
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
        HStack(spacing: 8) {
            attachmentButton
            MessageInputTextBar(
                text: $text,
                canSend: canSend,
                isSending: isSending,
                onSend: sendMessage,
                onStartVoice: startVoiceRecording
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var attachmentButton: some View {
        Button { showAttachmentMenu = true } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 22))
                .foregroundColor(Color.CT.textDim)
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
                selectedAttachments.append(MediaAttachment(image: image))
            }
            .ignoresSafeArea()
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !selectedAttachments.isEmpty
        || !selectedFileURLs.isEmpty
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
        let attachments = selectedAttachments.map { att -> MediaAttachment in
            var a = att; a.quality = quality; return a
        }
        onSend(attachments, selectedFileURLs)
        selectedPhotos.removeAll()
        selectedAttachments.removeAll()
        selectedFileURLs.removeAll()
    }

    private func removePhoto(at index: Int) {
        guard index < selectedAttachments.count else { return }
        selectedAttachments.remove(at: index)
        if index < selectedPhotos.count { selectedPhotos.remove(at: index) }
    }

    private func loadSelectedPhotos() async {
        selectedAttachments.removeAll()
        for item in selectedPhotos {
            // Keep the ORIGINAL bytes (+ mime) — original-quality sending (1b) needs them;
            // the compressed path (1a default) derives a display image from the same data.
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = PlatformImage(data: data) else { continue }
            if Int64(data.count) > MessageSizeLimits.maxImageBytes {
                Log.error("Photo too large", category: "MessageInput")
                continue
            }
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            selectedAttachments.append(MediaAttachment(originalData: data, mimeType: mime, displayImage: image))
        }
    }

    private func loadImagesFromURLs(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let image = PlatformImage(data: data) else { continue }
            if Int64(data.count) > MessageSizeLimits.maxImageBytes { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            selectedAttachments.append(MediaAttachment(originalData: data, mimeType: mime, displayImage: image))
        }
    }

    private func handlePickedFiles(_ urls: [URL]) {
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp", "bmp", "tiff"]
        for url in urls {
            if imageExts.contains(url.pathExtension.lowercased()) {
                loadImagesFromURLs([url])
            } else {
                do {
                    try MessageValidator.validateFile(at: url)
                    selectedFileURLs.append(url)
                } catch let error as MessageValidationError {
                    ErrorRouter.shared.report(error)
                } catch {
                    ErrorRouter.shared.report(.unknown(error.userFacingMessage))
                }
            }
        }
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

//#Preview("Input") {
//    @Previewable @State var text = ""
//    @Previewable @State var dropped: [PlatformImage] = []
//
//    VStack {
//        Spacer()
//        IOSMessageInputView(
//            text: $text,
//            droppedImages: $dropped,
//            isSending: false,
//            replyingTo: nil,
//            quoteOverride: nil,
//            editingMessage: nil,
//            onSend: { _, _ in },
//            onCancelReply: {},
//            onCancelEdit: {}
//        )
//    }
//    .background(Color.platformBackground)
//}
