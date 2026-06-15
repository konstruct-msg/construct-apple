//
//  MessageInputView+macOS.swift
//  Construct Messenger
//
//  macOS chat composer implementation: popover-based attachments and no
//  voice recorder/camera capture controls.
//

#if os(macOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MacMessageInputView: View {
    @Binding var text: String
    @Binding var droppedImages: [PlatformImage]
    let isSending: Bool
    let replyingTo: Message?
    let quoteOverride: String?
    let editingMessage: Message?
    let onSend: ([MediaAttachment], [URL]) -> Void
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void

    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedAttachments: [MediaAttachment] = []
    @State private var selectedFileURLs: [URL] = []
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            replyOrEditBars
            attachmentPreviews
            inputRow
        }
        .background(Color.CT.bg)
        .ctBorderTop()
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: replyingTo != nil)
        .animation(.easeInOut(duration: 0.2), value: editingMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: !selectedAttachments.isEmpty)
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
        }
        if !selectedFileURLs.isEmpty {
            MessageFilePreviewBar(fileURLs: selectedFileURLs) { index in
                selectedFileURLs.remove(at: index)
            }
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
                onStartVoice: nil
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
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 99, matching: .images)
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
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !selectedAttachments.isEmpty
        || !selectedFileURLs.isEmpty
    }

    private func sendMessage() {
        onSend(selectedAttachments, selectedFileURLs)
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
#endif
