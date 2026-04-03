//
//  MessageInputView.swift
//  Construct Messenger
//
//  Thin orchestrator: wires together reply/edit bars, attachment previews,
//  the attachment button, voice bars, and the text input pill.
//  All sub-views live in their own focused files.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MessageInputView: View {
    @Binding var text: String
    @Binding var droppedImages: [PlatformImage]
    let isSending: Bool
    let replyingTo: Message?
    /// Display override for the quoted snippet (partial quote).
    let quoteOverride: String?
    let editingMessage: Message?
    let onSend: ([PlatformImage], [URL]) -> Void
    var onSendVoice: ((URL, TimeInterval, [Float]) -> Void)? = nil
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void

    // MARK: - Attachment state
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [PlatformImage] = []
    @State private var selectedFileURLs: [URL] = []
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showCameraPicker = false
    @State private var isOptimizing = false

    // MARK: - Voice state
    @StateObject private var audioRecorder = AudioRecorderService.shared
    @State private var showMicPermissionAlert = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // Reply preview bar
            if let msg = replyingTo {
                MessageReplyBar(
                    content: quoteOverride ?? msg.decryptedContent,
                    messageId: msg.id,
                    onCancel: onCancelReply
                )
            }

            // Edit-mode banner
            if let msg = editingMessage {
                MessageEditBar(content: msg.decryptedContent ?? "", onCancel: onCancelEdit)
            }

            // Photo / file attachment previews
            if !selectedImages.isEmpty {
                MessagePhotoPreviewBar(images: selectedImages, onRemove: removePhoto)
            }
            if !selectedFileURLs.isEmpty {
                MessageFilePreviewBar(fileURLs: selectedFileURLs) { i in
                    selectedFileURLs.remove(at: i)
                }
            }

            // Main input row (or voice bars on iOS)
            #if os(iOS)
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
            #else
            inputRow
            #endif
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
                #if canImport(UIKit)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #endif
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

    // MARK: - Input row (attachment button + text pill)

    private var inputRow: some View {
        HStack(spacing: 8) {
            attachmentButton

            MessageInputTextBar(
                text: $text,
                canSend: canSend,
                isSending: isSending,
                onSend: sendMessage,
                onStartVoice: {
                    Task {
                        do {
                            try await audioRecorder.startRecording()
                        } catch AudioRecorderService.RecorderError.permissionDenied {
                            showMicPermissionAlert = true
                        } catch {
                            Log.error("❌ Recording failed: \(error)", category: "MessageInput")
                        }
                    }
                }
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Attachment button

    private var attachmentButton: some View {
        Button { showAttachmentMenu = true } label: {
            Text(CTSymbol.attach)
                .font(CTFont.bold(15))
                .foregroundColor(Color.CT.accentDim)
        }
        #if os(iOS)
        .confirmationDialog(LocalizedStringKey("attach"), isPresented: $showAttachmentMenu) {
            Button { showPhotoPicker = true } label: {
                Label(LocalizedStringKey("photos"), systemImage: "photo.on.rectangle")
            }
            Button(LocalizedStringKey("camera")) { showCameraPicker = true }
            Button(LocalizedStringKey("files")) { showFilePicker = true }
            Button(LocalizedStringKey("cancel"), role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos,
                      maxSelectionCount: 10, matching: .images)
        .sheet(isPresented: $showCameraPicker) {
            CameraPickerView { image in
                selectedImages.append(image)
            }
            .ignoresSafeArea()
        }
        #else
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos,
                      maxSelectionCount: 10, matching: .images)
        #endif
    }

    #if os(macOS)
    private func popoverButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(label), systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Computed helpers

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= MessageSizeLimits.maxTextCharacters)
        || !selectedImages.isEmpty
        || !selectedFileURLs.isEmpty
    }

    // MARK: - Actions

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

    // MARK: - Photo loading

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

// MARK: - Preview

#Preview("Input — idle") {
    @Previewable @State var text = ""
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        MessageInputView(
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
    .background(Color(.systemBackground))
}

#Preview("Input — with text") {
    @Previewable @State var text = "Hey there! 👋"
    @Previewable @State var dropped: [PlatformImage] = []

    VStack {
        Spacer()
        MessageInputView(
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
    .background(Color(.systemBackground))
}

// MARK: - Camera Picker (iOS only)

#if os(iOS)
import UIKit

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
#endif
