//
//  DesktopMessageInputView.swift
//  Construct Desktop
//
//  macOS-only message input bar.  Same interface as the iOS MessageInputView but
//  without UIKit dependencies: popover for the attachment menu, inline voice rows,
//  no camera picker, no confirmationDialog, no UIApplication.openSettingsURLString.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct DesktopMessageInputView: View {
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

    // MARK: - Attachment state

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [PlatformImage] = []
    @State private var selectedFileURLs: [URL] = []
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    // MARK: - Voice state

    @StateObject private var audioRecorder = AudioRecorderService.shared
    @State private var showMicPermissionAlert = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
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

            if !selectedImages.isEmpty {
                MessagePhotoPreviewBar(images: selectedImages, onRemove: removePhoto)
            }
            if !selectedFileURLs.isEmpty {
                MessageFilePreviewBar(fileURLs: selectedFileURLs) { i in
                    selectedFileURLs.remove(at: i)
                }
            }

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
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: replyingTo != nil)
        .animation(.easeInOut(duration: 0.2), value: editingMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: !selectedImages.isEmpty)
        .animation(.easeInOut(duration: 0.15), value: audioRecorder.state)
        // macOS: direct link to System Settings, no UIApplication
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

    // MARK: - Input row (pill with +, text field, and send/mic inside)

    private var inputRow: some View {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // macOS uses a popover instead of confirmationDialog (which is blocked in ZStack hierarchy)
        .popover(isPresented: $showAttachmentMenu, arrowEdge: .bottom) {
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
            maxSelectionCount: 10,
            matching: .images
        )
    }

    // MARK: - Voice rows (pill-styled to match the input pill)

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
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.CT.noise, lineWidth: 1))
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
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.CT.noise, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Popover helper

    private func popoverButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(label), systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Computed helpers

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

// MARK: - Previews

#if DEBUG
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
    .frame(width: 700, height: 200)
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
    .frame(width: 700, height: 200)
}
#endif
