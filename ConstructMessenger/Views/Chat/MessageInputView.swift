//
//  MessageInputView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import PhotosUI

struct MessageInputView: View {
    @Binding var text: String
    let isSending: Bool
    let replyingTo: Message?
    let onSend: ([UIImage]) -> Void  // Updated to pass images
    let onCancelReply: () -> Void

    // Photo attachment state
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var selectedImages: [UIImage] = []
    @State private var optimizedMedia: [OptimizedMedia] = []  // Optimized photos ready to send
    @State private var showAttachmentMenu = false
    @State private var showPhotoPicker = false  // Separate state for PhotosPicker
    @State private var validationError: String?
    @State private var isOptimizing = false

    var body: some View {
        VStack(spacing: 0) {
            // Reply preview bar
            if let replyMessage = replyingTo {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.AppBrand.second)
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
                    showAttachmentMenu = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Color.AppBrand.second)
                }
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
                        // TODO: Implement file picker
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

                HStack(spacing: 0) {
                    TextField("message_placeholder", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, 12)
                        .padding(.trailing, canSend ? 8 : 12)
                        .padding(.vertical, 8)
                        .modifier(MacReturnToSendModifier(text: $text, canSend: canSend, onSend: sendMessage))

                    if canSend {
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(canSend ? Color.AppBrand.second : .gray)
                                .padding(.trailing, 4)
                        }
                        .disabled(!canSend || isSending)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .background(Color(uiColor: .systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))
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
                    onSend()
                }
                return .handled
            }
#else
        content
#endif
    }
}
