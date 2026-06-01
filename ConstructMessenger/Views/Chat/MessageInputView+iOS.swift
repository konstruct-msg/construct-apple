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
import UIKit

struct IOSMessageInputView: View {
    @Binding var text: String
    @Binding var droppedImages: [PlatformImage]
    let isSending: Bool
    let replyingTo: Message?
    let quoteOverride: String?
    let editingMessage: Message?
    let onSend: ([PlatformImage], [URL]) -> Void
    var onSendVoice: ((URL, TimeInterval, [Float]) -> Void)? = nil
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [PlatformImage] = []
    @State private var selectedFileURLs: [URL] = []
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showCameraPicker = false
    @StateObject private var audioRecorder = AudioRecorderService.shared
    @State private var showMicPermissionAlert = false

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
        .animation(.easeInOut(duration: 0.2), value: !selectedImages.isEmpty)
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
            selectedImages.append(contentsOf: newImages)
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
        if !selectedImages.isEmpty {
            MessagePhotoPreviewBar(images: selectedImages, onRemove: removePhoto)
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 10, matching: .images)
        .sheet(isPresented: $showCameraPicker) {
            CameraPickerView { image in
                selectedImages.append(image)
            }
            .ignoresSafeArea()
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !selectedImages.isEmpty
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
        onSend(selectedImages, selectedFileURLs)
        selectedPhotos.removeAll()
        selectedImages.removeAll()
        selectedFileURLs.removeAll()
    }

    private func removePhoto(at index: Int) {
        guard index < selectedImages.count else { return }
        selectedImages.remove(at: index)
        if index < selectedPhotos.count { selectedPhotos.remove(at: index) }
    }

    private func loadSelectedPhotos() async {
        selectedImages.removeAll()
        for item in selectedPhotos {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = PlatformImage(data: data) else { continue }
            if let jpeg = image.platformJPEGData(quality: 0.8),
               Int64(jpeg.count) > MessageSizeLimits.maxImageBytes {
                Log.error("Photo too large", category: "MessageInput")
                continue
            }
            selectedImages.append(image)
        }
    }

    private func loadImagesFromURLs(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let image = PlatformImage(data: data) else { continue }
            if let jpeg = image.platformJPEGData(quality: 0.8),
               Int64(jpeg.count) > MessageSizeLimits.maxImageBytes { continue }
            selectedImages.append(image)
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
