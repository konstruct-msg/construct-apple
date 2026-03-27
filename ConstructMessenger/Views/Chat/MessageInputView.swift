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
    var onSendVoice: ((URL, TimeInterval, [Float]) -> Void)? = nil
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

    @StateObject private var audioRecorder = AudioRecorderService.shared
    @State private var showMicPermissionAlert = false

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
#else
                // macOS: popover with Photos and Files options
                .popover(isPresented: $showAttachmentMenu, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            showAttachmentMenu = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                showPhotoPicker = true
                            }
                        } label: {
                            Label(LocalizedStringKey("photos"), systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        Divider()

                        Button {
                            showAttachmentMenu = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                showFilePicker = true
                            }
                        } label: {
                            Label(LocalizedStringKey("files"), systemImage: "paperclip")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(width: 180)
                }
                .photosPicker(
                    isPresented: $showPhotoPicker,
                    selection: $selectedPhotos,
                    maxSelectionCount: 10,
                    matching: .images
                )
#endif

                // Voice recording/preview bars replace the text input entirely on iOS
                #if os(iOS) && !targetEnvironment(macCatalyst)
                switch audioRecorder.state {
                case .recording(let duration, let waveform):
                    VoiceRecordingBar(duration: duration, waveform: waveform) {
                        audioRecorder.stopRecording()
                    } onCancel: {
                        audioRecorder.cancel()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .recorded(let url, let duration, let waveform):
                    VoicePreviewBar(duration: duration, waveform: waveform) {
                        onSendVoice?(url, duration, waveform)
                        audioRecorder.resetAfterSend()
                    } onDiscard: {
                        audioRecorder.cancel()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                case .idle:
                    EmptyView()
                }
                #endif

                // Show text input only when not recording/previewing voice
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
#elseif os(macOS)
                    // Use TextEditor on macOS to avoid NSSplitView infinite
                    // constraint loop caused by TextField(axis:) with lineLimit range.
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(LocalizedStringKey("message_placeholder"))
                                .foregroundStyle(.secondary)
                                .font(.system(size: 13))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .focused($isTextFieldFocused)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .onKeyPress(keys: [.return], phases: .down) { press in
                                if press.modifiers.contains(.shift) {
                                    return .ignored
                                }
                                if canSend { sendMessage(); text = "" }
                                return .handled
                            }
                    }
                    .frame(minHeight: 36, maxHeight: 120)
                    .padding(.trailing, canSend ? 8 : 12)
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
#elseif os(macOS)
                            // macOS: compact send button (Enter also sends)
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 26, height: 26)
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.trailing, 6)
                            .help("Send (⏎) · New line (⇧⏎)")
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

                    #if os(iOS) && !targetEnvironment(macCatalyst)
                    if !canSend, case .idle = audioRecorder.state {
                        Button {
                            Task {
                                do {
                                    try await audioRecorder.startRecording()
                                } catch AudioRecorderService.RecorderError.permissionDenied {
                                    showMicPermissionAlert = true
                                } catch {
                                    Log.error("❌ Recording failed: \(error)", category: "MessageInput")
                                }
                            }
                        } label: {
                            Image(systemName: "waveform")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.secondary)
                                .padding(.trailing, 6)
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                    }
                    #endif
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
                #if os(iOS) && !targetEnvironment(macCatalyst)
                .opacity(isVoiceActive ? 0 : 1)
                .frame(maxHeight: isVoiceActive ? 0 : nil)
                .clipped()
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

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var isVoiceActive: Bool {
        if case .idle = audioRecorder.state { return false }
        return true
    }
    #endif

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

// MARK: - Voice Recording Bar

#if os(iOS) && !targetEnvironment(macCatalyst)

// MARK: - Voice Recording Bar (full-width accent pill, replaces text input)

private struct VoiceRecordingBar: View {
    let duration: TimeInterval
    let waveform: [Float]
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Cancel button — white circle
            Button(action: onCancel) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 44, height: 44)
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)

            // Live waveform
            LiveWaveformView(samples: waveform)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 12)

            // Timer
            Text(durationLabel)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 42, alignment: .trailing)

            // Stop button — white circle with red square
            Button(action: onStop) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 44, height: 44)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red)
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .padding(.trailing, 8)
        }
        .frame(height: 56)
        .background(Color.accentColor)
        .clipShape(Capsule())
        .padding(.horizontal)
    }

    private var durationLabel: String {
        let s = Int(duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Voice Preview Bar (full-width accent pill, replaces text input)

private struct VoicePreviewBar: View {
    let duration: TimeInterval
    let waveform: [Float]
    let onSend: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Discard button — white circle with trash icon
            Button(action: onDiscard) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 44, height: 44)
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)

            // Static waveform dots
            StaticWaveformView(samples: waveform)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .padding(.horizontal, 12)

            // Duration
            Text(durationLabel)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 42, alignment: .trailing)

            // Send button — white circle with paper plane
            Button(action: onSend) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 44, height: 44)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .offset(x: 1)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .padding(.trailing, 8)
        }
        .frame(height: 56)
        .background(Color.accentColor)
        .clipShape(Capsule())
        .padding(.horizontal)
    }

    private var durationLabel: String {
        let s = Int(duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Live Waveform (recording) — bars from the right edge showing latest samples

private struct LiveWaveformView: View {
    let samples: [Float]
    private let barCount = 36
    private let barSpacing: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = barSpacing * CGFloat(barCount - 1)
            let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(barOpacity(for: i)))
                        .frame(width: barWidth, height: barHeight(for: i, total: geo.size.height))
                }
            }
        }
    }

    private func barHeight(for index: Int, total: CGFloat) -> CGFloat {
        let count = samples.count
        guard count > 0 else { return 4 }
        let sampleIndex = max(0, count - barCount + index)
        guard sampleIndex < count else { return 4 }
        return max(4, CGFloat(samples[sampleIndex]) * total * 0.9)
    }

    // Bars fade in from the left as they fill up
    private func barOpacity(for index: Int) -> Double {
        let count = samples.count
        guard count < barCount else { return 1.0 }
        let startVisible = barCount - count
        return index >= startVisible ? 1.0 : 0.25
    }
}

// MARK: - Static Waveform (preview) — evenly downsampled bars

private struct StaticWaveformView: View {
    let samples: [Float]
    private let barCount = 36
    private let barSpacing: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = barSpacing * CGFloat(barCount - 1)
            let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.80))
                        .frame(width: barWidth, height: barHeight(for: i, total: geo.size.height))
                }
            }
        }
    }

    private func barHeight(for index: Int, total: CGFloat) -> CGFloat {
        guard !samples.isEmpty else { return 5 }
        let step = Float(samples.count) / Float(barCount)
        let si = Int(Float(index) * step)
        let ei = min(Int(Float(index + 1) * step), samples.count)
        guard si < ei else { return 5 }
        let avg = samples[si..<ei].reduce(0, +) / Float(ei - si)
        return max(5, CGFloat(avg) * total * 0.85)
    }
}
#endif
