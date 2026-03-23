//
//  MessageInputView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct MessageInputView: View {
    @Binding var text: String
    @Binding var droppedImages: [PlatformImage]  // Images pushed from ChatView drop zone
    let isSending: Bool
    let replyingTo: Message?
    /// Optional override for the quoted text shown in the reply bar.
    /// When set (partial quote), this is displayed instead of replyingTo.decryptedContent.
    let quoteOverride: String?
    let editingMessage: Message?
    let onSend: ([PlatformImage], [URL]) -> Void  // images + file URLs
    let onCancelReply: () -> Void
    let onCancelEdit: () -> Void

    // Photo attachment state
    @FocusState private var isTextFieldFocused: Bool
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [PlatformImage] = []
    @State private var optimizedMedia: [OptimizedMedia] = []  // Optimized photos ready to send
    @State private var selectedFileURLs: [URL] = []           // Document attachments
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false  // Separate state for PhotosPicker
    @State private var showFilePicker = false   // document file importer
    @State private var validationError: String?
    @State private var isOptimizing = false

    var body: some View {
        VStack(spacing: 0) {
            // Reply preview bar
            if let replyMessage = replyingTo {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("reply_to_colon")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ReplyPreviewContent(
                            content: quoteOverride ?? replyMessage.decryptedContent,
                            messageId: replyMessage.id,
                            thumbnailSize: 36,
                            lineLimit: 1
                        )
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        onCancelReply()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.title3)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxHeight: 50)
                #if canImport(UIKit)
                .background(Color(uiColor: .systemGray6))
                #else
                .background(Color(nsColor: .windowBackgroundColor))
                #endif
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Edit mode banner
            if let editMessage = editingMessage {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("editing_message", comment: ""))
                            .font(.caption)
                            .foregroundColor(.orange)

                        Text(editMessage.decryptedContent ?? "")
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    Button {
                        onCancelEdit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.title3)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxHeight: 50)
                #if canImport(UIKit)
                .background(Color(uiColor: .systemGray6))
                #else
                .background(Color(nsColor: .windowBackgroundColor))
                #endif
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !selectedImages.isEmpty {
                photoPreviewView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // File preview (if document files selected)
            if !selectedFileURLs.isEmpty {
                filePreviewView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input field
            HStack(spacing: 8) {
                // Attachment button (+ icon)
                Button {
                    showAttachmentMenu = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color.blue)
                }
#if os(iOS)
                .confirmationDialog(LocalizedStringKey("attach"), isPresented: $showAttachmentMenu) {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label(LocalizedStringKey("photos"), systemImage: "photo.on.rectangle")
                    }

                    Button(LocalizedStringKey("camera")) {
                        // TODO: Implement camera
                    }

                    Button(LocalizedStringKey("files")) {
                        showFilePicker = true
                    }

                    Button(LocalizedStringKey("cancel"), role: .cancel) {}
                }
                // PhotosPicker as sheet (the correct way)
                .photosPicker(
                    isPresented: $showPhotoPicker,
                    selection: $selectedPhotos,
                    maxSelectionCount: 10,
                    matching: .images
                )
#endif

                HStack(spacing: 0) {
#if targetEnvironment(macCatalyst)
                    CatalystGrowingTextView(
                        text: $text,
                        placeholder: NSLocalizedString("message_placeholder", comment: ""),
                        canSend: canSend,
                        onSend: sendMessage
                    )
                    .frame(minHeight: 36, maxHeight: 120)
                    .padding(.leading, 12)
                    .padding(.trailing, canSend ? 8 : 12)
                    .padding(.vertical, 8)
#else
                    TextField("message_placeholder", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, 12)
                        .padding(.trailing, canSend ? 8 : 12)
                        .padding(.vertical, 8)
                        .focused($isTextFieldFocused)
#endif

                    if showCharCounter {
                        charCounterView
                            .transition(.opacity)
                    }

                    if canSend {
                        Button {
                            sendMessage()
                        } label: {
#if targetEnvironment(macCatalyst)
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 26, height: 26)
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .offset(x: 1)
                            }
                            .padding(.trailing, 6)
#else
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(canSend ? Color.blue : .gray)
                                .padding(.trailing, 4)
#endif
                        }
                        .disabled(!canSend || isSending)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                #if canImport(UIKit)
                .background(Color(uiColor: .systemGray6))
                #else
                .background(Color(nsColor: .windowBackgroundColor))
                #endif
#if targetEnvironment(macCatalyst)
                .clipShape(RoundedRectangle(cornerRadius: 8))
#else
                .clipShape(RoundedRectangle(cornerRadius: 20))
#endif
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color.AppBackground.primary)
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .animation(.easeInOut(duration: 0.2), value: replyingTo != nil)
        .animation(.easeInOut(duration: 0.2), value: editingMessage != nil)
        .animation(.easeInOut(duration: 0.2), value: !selectedImages.isEmpty)
        .onChange(of: selectedPhotos) {
            Task {
                await loadSelectedPhotos()
            }
        }
        .onChange(of: droppedImages) { _, newImages in
            guard !newImages.isEmpty else { return }
            selectedImages.append(contentsOf: newImages)
            droppedImages.removeAll()
        }
        // macOS / iOS: file importer — accepts all file types
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                handlePickedFiles(urls)
            case .failure(let error):
                Log.error("❌ File picker error: \(error)", category: "MessageInput")
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= MessageSizeLimits.maxTextCharacters
            || !selectedImages.isEmpty
            || !selectedFileURLs.isEmpty
    }

    private var isOverLimit: Bool { text.count > MessageSizeLimits.maxTextCharacters }

    private var showCharCounter: Bool { text.count > MessageSizeLimits.maxTextCharacters - 200 }

    private var charCounterView: some View {
        let remaining = MessageSizeLimits.maxTextCharacters - text.count
        return Text(remaining >= 0 ? "\(remaining)" : "\(-remaining) over limit")
            .font(.caption2)
            .foregroundColor(isOverLimit ? .red : .secondary)
            .padding(.trailing, 4)
    }

    // MARK: - Photo Preview
    private var photoPreviewView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        // Remove button
                        Button {
                            removePhoto(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        #if canImport(UIKit)
        .background(Color(uiColor: .systemGray6))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }

    // MARK: - File Preview

    private var filePreviewView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(selectedFileURLs.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 6) {
                        Image(systemName: fileIcon(for: url.pathExtension))
                            .foregroundColor(.accentColor)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if let size = fileSize(url) {
                                Text(size)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Button {
                            selectedFileURLs.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    #if canImport(UIKit)
                    .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 8))
                    #else
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        #if canImport(UIKit)
        .background(Color(uiColor: .systemGray6))
        #else
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }

    private func fileIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "md", "markdown": return "doc.text"
        case "txt": return "doc.text"
        case "zip", "gz", "tar": return "archivebox"
        case "mp3", "aac", "m4a", "wav": return "music.note"
        case "mp4", "mov", "avi": return "video"
        default: return "doc"
        }
    }

    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Photo Loading
    private func loadSelectedPhotos() async {
        selectedImages.removeAll()

        for item in selectedPhotos {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = PlatformImage(data: data) else {
                continue
            }

            // Validate size
            if let imageData = image.platformJPEGData(quality: 0.8) {
                let sizeInBytes = Int64(imageData.count)
                if sizeInBytes > MessageSizeLimits.maxImageBytes {
                    // TODO: Show error to user
                    Log.error("Photo too large: \(MessageSizeLimits.formatFileSize(sizeInBytes))", category: "MessageInput")
                    continue
                }
            }

            selectedImages.append(image)
        }
    }

    private func removePhoto(at index: Int) {
        guard index < selectedImages.count else { return }
        selectedImages.remove(at: index)
        if index < selectedPhotos.count {
            selectedPhotos.remove(at: index)
        }
    }

    private func loadImagesFromURLs(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let image = PlatformImage(data: data) else { continue }
            if let jpeg = image.platformJPEGData(quality: 0.8),
               Int64(jpeg.count) > MessageSizeLimits.maxImageBytes {
                Log.error("Photo too large: \(url.lastPathComponent)", category: "MessageInput")
                continue
            }
            selectedImages.append(image)
        }
    }

    /// Separates picked URLs into images (loaded into selectedImages) and
    /// other files (kept as security-scoped URLs in selectedFileURLs).
    private func handlePickedFiles(_ urls: [URL]) {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp", "bmp", "tiff"]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if imageExtensions.contains(ext) {
                loadImagesFromURLs([url])
            } else {
                do {
                    try MessageValidator.validateFile(at: url)
                    selectedFileURLs.append(url)
                } catch let error as MessageValidationError {
                    ErrorRouter.shared.report(error)
                    Log.error("❌ File validation failed: \(error.localizedDescription)", category: "MessageInput")
                } catch {
                    ErrorRouter.shared.report(.unknown(error.userFacingMessage))
                    Log.error("❌ Unexpected file validation error: \(error)", category: "MessageInput")
                }
            }
        }
    }

    private func sendMessage() {
        onSend(selectedImages, selectedFileURLs)
        selectedPhotos.removeAll()
        selectedImages.removeAll()
        selectedFileURLs.removeAll()
    }
}
