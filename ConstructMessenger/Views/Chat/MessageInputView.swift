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
    let isSending: Bool
    let replyingTo: Message?
    let onSend: ([UIImage]) -> Void  // Updated to pass images
    let onCancelReply: () -> Void

    // Photo attachment state
    @FocusState private var isTextFieldFocused: Bool
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var optimizedMedia: [OptimizedMedia] = []  // Optimized photos ready to send
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false  // Separate state for PhotosPicker
    @State private var showFilePicker = false   // macOS: file importer
    @State private var isDropTargeted = false   // macOS: drag-and-drop highlight
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

                        Text(replyMessage.decryptedContent ?? NSLocalizedString("message", comment: "Fallback for reply preview"))
                            .font(.subheadline)
                            .lineLimit(1)
                            .foregroundColor(.primary)
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
                .background(Color(uiColor: .systemGray6))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Photo preview (if photos selected)
            if !selectedImages.isEmpty {
                photoPreviewView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Input field
            HStack(spacing: 8) {
                // Attachment button (+ icon)
                Button {
#if targetEnvironment(macCatalyst)
                    showFilePicker = true
#else
                    showAttachmentMenu = true
#endif
                } label: {
#if targetEnvironment(macCatalyst)
                    Image(systemName: "paperclip")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
#else
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color.blue)
#endif
                }
#if !targetEnvironment(macCatalyst)
                .confirmationDialog("Attach", isPresented: $showAttachmentMenu) {
                    Button {
                        showPhotoPicker = true
                    } label: {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }

                    Button("Camera") {
                        // TODO: Implement camera
                    }

                    Button("Files") {
                        showFilePicker = true
                    }

                    Button("Cancel", role: .cancel) {}
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
                    TextField("message_placeholder", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, 12)
                        .padding(.trailing, canSend ? 8 : 12)
                        .padding(.vertical, 8)
                        .focused($isTextFieldFocused)
                        .modifier(MacReturnToSendModifier(text: $text, canSend: canSend, onSend: sendMessage))

                    if canSend {
                        Button {
                            sendMessage()
                        } label: {
#if targetEnvironment(macCatalyst)
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 26, height: 26)
                                Image(systemName: "paperplane.fill")
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
                .background(Color(uiColor: .systemGray6))
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
        .animation(.easeInOut(duration: 0.2), value: !selectedImages.isEmpty)
        .onChange(of: selectedPhotos) {
            Task {
                await loadSelectedPhotos()
            }
        }
        // macOS / iOS: file importer (Finder open panel)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.image, .jpeg, .png, .heic, .gif, .webP, .bmp, .tiff],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                loadImagesFromURLs(urls)
            case .failure(let error):
                Log.error("❌ File picker error: \(error)", category: "MessageInput")
            }
        }
        // macOS: drag-and-drop images from Finder onto the input bar
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay(alignment: .center) {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 8)))
                    .overlay(
                        Label("Drop images here", systemImage: "photo.badge.plus")
                            .foregroundColor(.accentColor)
                            .font(.headline)
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedImages.isEmpty
    }

    // MARK: - Photo Preview
    private var photoPreviewView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(selectedImages.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
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
        .background(Color(uiColor: .systemGray6))
    }

    // MARK: - Photo Loading
    private func loadSelectedPhotos() async {
        selectedImages.removeAll()

        for item in selectedPhotos {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                continue
            }

            // Validate size
            if let imageData = image.jpegData(compressionQuality: 0.8) {
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
        guard index < selectedImages.count && index < selectedPhotos.count else { return }
        selectedImages.remove(at: index)
        selectedPhotos.remove(at: index)
    }

    private func loadImagesFromURLs(_ urls: [URL]) {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { continue }
            if let jpeg = image.jpegData(compressionQuality: 0.8),
               Int64(jpeg.count) > MessageSizeLimits.maxImageBytes {
                Log.error("Photo too large: \(url.lastPathComponent)", category: "MessageInput")
                continue
            }
            selectedImages.append(image)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let image = UIImage(data: data) else { return }
                    DispatchQueue.main.async { selectedImages.append(image) }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { loadImagesFromURLs([url]) }
                }
                handled = true
            }
        }
        return handled
    }

    private func sendMessage() {
        onSend(selectedImages)
        // Clear photos after sending
        selectedPhotos.removeAll()
        selectedImages.removeAll()
    }
}

// MARK: - Mac Catalyst: Return = send, Shift+Return = newline

/// On Mac Catalyst, intercepts the Return key so pressing Return sends the message
/// and Shift+Return inserts a newline. Has no effect on iOS/iPadOS.
private struct MacReturnToSendModifier: ViewModifier {
    @Binding var text: String
    let canSend: Bool
    let onSend: () -> Void

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) {
                    // Shift+Return → insert newline at end of text
                    text += "\n"
                    return .handled
                }
                // Return → send (if there is content to send)
                if canSend {
                    // Strip any trailing newline UIKit may have already inserted
                    text = text.trimmingCharacters(in: .newlines)
                    onSend()
                }
                return .handled
            }
#else
        content
#endif
    }
}
