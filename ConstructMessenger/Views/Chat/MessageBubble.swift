//
//  MessageBubble.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import QuickLook

struct MessageBubble: View {
    /// Observed so the view re-renders when deliveryStatusRaw (or any @NSManaged property) changes.
    /// NSManagedObject conforms to ObservableObject via KVO, so SwiftUI subscribes automatically.
    @ObservedObject var message: Message
    let isLastInGroup: Bool
    let isSelected: Bool
    let isEditMode: Bool
    let onRetry: ((Message) -> Void)?
    let onReply: ((Message) -> Void)?
    let onDelete: ((Message) -> Void)?
    let onSelect: ((Message) -> Void)?
    let onEnterSelectMode: ((Message) -> Void)?
    let onTapMedia: ((Message) -> Void)?
    let onEdit: ((Message) -> Void)?
    /// Called when the user chooses "Quote & Reply" — provides the message and the selected quote text.
    let onReplyWithQuote: ((Message, String) -> Void)?

    @Environment(\.containerWidth) private var containerWidth
    @State private var swipeOffset: CGFloat = 0

    init(
        message: Message,
        isLastInGroup: Bool = true,
        isSelected: Bool = false,
        isEditMode: Bool = false,
        onRetry: ((Message) -> Void)? = nil,
        onReply: ((Message) -> Void)? = nil,
        onDelete: ((Message) -> Void)? = nil,
        onSelect: ((Message) -> Void)? = nil,
        onEnterSelectMode: ((Message) -> Void)? = nil,
        onTapMedia: ((Message) -> Void)? = nil,
        onEdit: ((Message) -> Void)? = nil,
        onReplyWithQuote: ((Message, String) -> Void)? = nil
    ) {
        self.message = message
        self.isLastInGroup = isLastInGroup
        self.isSelected = isSelected
        self.isEditMode = isEditMode
        self.onRetry = onRetry
        self.onReply = onReply
        self.onDelete = onDelete
        self.onSelect = onSelect
        self.onEnterSelectMode = onEnterSelectMode
        self.onTapMedia = onTapMedia
        self.onEdit = onEdit
        self.onReplyWithQuote = onReplyWithQuote
    }

    var body: some View {
        // Guard against accessing a deleted or faulted Core Data object.
        // This can happen when a placeholder is deleted while SwiftUI still
        // holds a stale reference to it (between FRC delete notification and
        // the next SwiftUI layout pass).
        guard !message.isDeleted, message.managedObjectContext != nil else {
            return AnyView(EmptyView())
        }
        // ✅ Check if this is a system message by fromUserId
        if message.fromUserId == "SYSTEM" {
            return AnyView(systemMessageView(message.decryptedContent ?? "System message"))
        } else if let content = message.decryptedContent, content.hasPrefix("[SYSTEM]") {
            // ✅ Legacy support for [SYSTEM] prefix
            return AnyView(systemMessageView(content.replacingOccurrences(of: "[SYSTEM]", with: "").trimmingCharacters(in: .whitespaces)))
        } else {
            return AnyView(regularMessageView)
        }
    }
    
    // MARK: - System Message View
    private func systemMessageView(_ content: String) -> some View {
        HStack {
            Spacer()
            Text(content)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(12)
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Regular Message View
    private var regularMessageView: some View {
        HStack(spacing: 8) {
            // Selection checkbox in edit mode - positioned based on message direction
            if isEditMode && !message.isSentByMe {
                // Checkbox on LEFT for incoming messages
                Button {
                    onSelect?(message)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? Color.blue : .gray)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            if message.isSentByMe {
                Spacer(minLength: 60)
            }

            VStack(alignment: message.isSentByMe ? .trailing : .leading, spacing: 4) {
                // ✅ Check if this is a profile share message
                if let content = message.decryptedContent,
                   let profileData = parseProfileMessage(content) {
                    // Display profile card
                    ProfileShareBubbleView(profileData: profileData)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                        )
                }
                // ✅ Check if this is a media message
                else if let mediaContent = parseMediaMessage(message.decryptedContent) {
                    // Display media message without bubble - just rounded corners
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        MediaMessageView(mediaContent: mediaContent, message: message, isSelected: isSelected, onTapFullScreen: { onTapMedia?(message) })
                    }
                }
                // ✅ Check if this is a file attachment message
                else if let fileContent = parseFileMessage(message.decryptedContent) {
                    VStack(alignment: .leading, spacing: 0) {
                        replyIndicatorView
                        FileAttachmentBubbleView(fileContent: fileContent, isSentByMe: message.isSentByMe)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                            )
                    }
                } else {
                    // Text message bubble: reply indicator lives INSIDE the bubble background
                    // so the quote block and the message text share one visual container.
                    VStack(alignment: .leading, spacing: 0) {
                        // Reply quote at the top of the bubble (if present)
                        replyIndicatorView

                        VStack(alignment: .leading, spacing: 4) {
                            // Main message content
                            if message.decryptedContent == nil {
                                // Irrecoverable: message was saved when the session was unavailable
                                // or decryption failed. Display a clear unavailable indicator.
                                HStack(spacing: 5) {
                                    Image(systemName: "lock.trianglebadge.exclamationmark")
                                        .font(.caption)
                                    Text(NSLocalizedString("message_unavailable", comment: ""))
                                        .italic()
                                }
                                .font(.callout)
                                .foregroundColor(.secondary)
                            } else {
                                LinkDetectingText(
                                    message.decryptedContent!,
                                    color: message.isSentByMe ? .white : .primary
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        // Reduce top padding when reply bar is shown — it already provides spacing.
                        .padding(.top, message.replyToContent != nil ? 4 : 8)
                        .padding(.bottom, 8)
                    }
                    #if canImport(UIKit)
                    .background(
                        isSelected
                            ? (message.isSentByMe ? Color.accentColor.opacity(0.75) : Color.accentColor.opacity(0.15))
                            : (message.isSentByMe ? Color.accentColor : Color(uiColor: .systemGray5))
                    )
                    #else
                    .background(
                        isSelected
                            ? (message.isSentByMe ? Color.accentColor.opacity(0.75) : Color.accentColor.opacity(0.15))
                            : (message.isSentByMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    )
                    #endif
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                if isLastInGroup {
                    HStack(spacing: 4) {
                        if message.isSentByMe {
                            deliveryStatusView
                        }

                        if message.isEdited {
                            Text(NSLocalizedString("edited", comment: ""))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: containerWidth * 0.7, alignment: message.isSentByMe ? .trailing : .leading)
            .contentShape(.interaction, Rectangle())
            #if os(iOS)
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 8))
            #endif
            .onTapGesture {
                if isEditMode {
                    onSelect?(message)
                }
            }
            .contextMenu {
                if !isEditMode {
                    if let onReply = onReply {
                        Button {
                            onReply(message)
                        } label: {
                            Label("reply", systemImage: "arrowshape.turn.up.left")
                        }
                    }

                    // "Quote & Reply" — only for plain text messages
                    if let onReplyWithQuote,
                       let content = message.decryptedContent,
                       parseMediaContent(from: content) == nil,
                       parseFileMessage(content) == nil {
                        Button {
                            onReplyWithQuote(message, content)
                        } label: {
                            Label(NSLocalizedString("quote_reply", comment: ""), systemImage: "text.quote")
                        }
                    }

                    if message.isSentByMe,
                       message.decryptedContent != nil,
                       !message.decryptedContent!.hasPrefix("[MEDIA]"),
                       !message.decryptedContent!.hasPrefix("[FILE]"),
                       let onEdit = onEdit {
                        Button {
                            onEdit(message)
                        } label: {
                            Label(NSLocalizedString("edit_message", comment: ""), systemImage: "pencil")
                        }
                    }

                    Button {
                        PlatformClipboard.copy(message.decryptedContent ?? "")
                    } label: {
                        Label("copy", systemImage: "doc.on.doc")
                    }

                    if let onEnterSelectMode = onEnterSelectMode {
                        Button {
                            onEnterSelectMode(message)
                        } label: {
                            Label("select_messages", systemImage: "checkmark.circle")
                        }
                    }

                    Divider()

                    if let onDelete = onDelete {
                        Button(role: .destructive) {
                            onDelete(message)
                        } label: {
                            Label("delete", systemImage: "trash")
                        }
                    }

                    if (message.deliveryStatus == .failed || message.deliveryStatus == .queued),
                       let onRetry = onRetry {
                        Button {
                            onRetry(message)
                        } label: {
                            Label("retry", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            // Swipe-to-reply: right swipe triggers onReply when not in edit mode
            .offset(x: swipeOffset)
            .gesture(
                isEditMode ? nil : DragGesture(minimumDistance: 20, coordinateSpace: .local)
                    .onChanged { value in
                        let h = value.translation.width
                        let v = abs(value.translation.height)
                        guard h > 0, h > v else { return }
                        swipeOffset = min(h * 0.5, 60)
                    }
                    .onEnded { _ in
                        if swipeOffset >= 40 {
                            onReply?(message)
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            swipeOffset = 0
                        }
                    }
            )
            .overlay(alignment: message.isSentByMe ? .leading : .trailing) {
                if swipeOffset > 10 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .opacity(min(max(Double(swipeOffset / 40), 0), 1))
                        .offset(x: message.isSentByMe ? -swipeOffset - 8 : swipeOffset + 8)
                        .animation(.interactiveSpring(), value: swipeOffset)
                }
            }

            if !message.isSentByMe {
                Spacer(minLength: 60)
            }
            
            // Selection checkbox in edit mode - positioned based on message direction
            if isEditMode && message.isSentByMe {
                Button {
                    onSelect?(message)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isSelected ? Color.blue : .gray)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        let status = message.deliveryStatus

        switch status {
        case .sending:
            // Uploading — outline circle, message in transit
            Circle()
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 10, height: 10)

        case .sent:
            // Server acknowledged — filled gray circle
            Circle()
                .fill(Color.secondary.opacity(0.6))
                .frame(width: 10, height: 10)

        case .delivered:
            // Delivered to recipient — filled StillGreen circle
            Circle()
                .fill(Color.green)
                .frame(width: 10, height: 10)

        case .queued:
            Button {
                if let onRetry = onRetry {
                    onRetry(message)
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "tray")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("retry")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

        case .failed:
            Button {
                if let onRetry = onRetry {
                    onRetry(message)
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("retry")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
    }
    
    // MARK: - Media Message Parsing
    
    private func parseProfileMessage(_ content: String) -> ProfileShareData? {
        guard let data = content.data(using: .utf8) else { return nil }
        
        // Check if it looks like a profile message
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = jsonDict["type"] as? String,
           type == "profile" {
            // Try to decode it properly
            return try? JSONDecoder().decode(ProfileShareData.self, from: data)
        }
        return nil
    }
    
    private func parseMediaMessage(_ content: String?) -> MediaMessageContent? {
        parseMediaContent(from: content)
    }

    private func parseFileMessage(_ content: String?) -> FileMessageContent? {
        guard let content,
              let data = content.data(using: .utf8),
              let json = try? JSONDecoder().decode(FileMessageContent.self, from: data),
              json.type == "file"
        else { return nil }
        return json
    }

    /// Reply context bar shown above message content, rendered INSIDE the bubble background.
    @ViewBuilder
    private var replyIndicatorView: some View {
        if let replyContent = message.replyToContent {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)

                ReplyPreviewContent(
                    content: replyContent,
                    messageId: message.replyToMessageId,
                    thumbnailSize: 40,
                    lineLimit: 2
                )
                .padding(.vertical, 4)
                .padding(.trailing, 4)
            }
            // Match the bubble's horizontal padding so the accent bar aligns with the message text.
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - File Attachment Bubble View

struct FileAttachmentBubbleView: View {
    let fileContent: FileMessageContent
    let isSentByMe: Bool

    @State private var downloadedURLs: [String: URL] = [:]   // mediaId → temp file URL
    @State private var downloading: Set<String> = []
    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fileContent.files, id: \.mediaId) { file in
                fileRow(file)
            }
            if !fileContent.caption.isEmpty {
                Text(fileContent.caption)
                    .font(.subheadline)
                    .foregroundColor(isSentByMe ? .white : .primary)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        #if canImport(UIKit)
        .background(isSentByMe ? Color.accentColor : Color(uiColor: .systemGray5))
        #else
        .background(isSentByMe ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .quickLookPreview($previewURL)
    }

    @ViewBuilder
    private func fileRow(_ file: FileMessageContent.FileEntry) -> some View {
        Button {
            openOrDownload(file)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: file.filename))
                    .font(.system(size: 22))
                    .foregroundColor(isSentByMe ? .white.opacity(0.9) : .accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(isSentByMe ? .white : .primary)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .font(.caption)
                        .foregroundColor(isSentByMe ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                if downloading.contains(file.mediaId) {
                    ProgressView()
                        .tint(isSentByMe ? .white : .accentColor)
                        .scaleEffect(0.8)
                } else if downloadedURLs[file.mediaId] != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(isSentByMe ? .white.opacity(0.8) : .green)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(isSentByMe ? .white.opacity(0.8) : .accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func openOrDownload(_ file: FileMessageContent.FileEntry) {
        if let url = downloadedURLs[file.mediaId] {
            previewURL = url
            return
        }
        guard !downloading.contains(file.mediaId) else { return }
        downloading.insert(file.mediaId)

        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptFile(
                    mediaId: file.mediaId,
                    mediaUrl: file.mediaUrl,
                    mediaKeyBase64: file.mediaKey,
                    compressed: file.compressed
                )
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(file.filename)
                try data.write(to: tmpURL)
                await MainActor.run {
                    downloadedURLs[file.mediaId] = tmpURL
                    downloading.remove(file.mediaId)
                    previewURL = tmpURL
                }
            } catch {
                await MainActor.run {
                    downloading.remove(file.mediaId)
                    Log.error("❌ File download failed: \(error)", category: "FileAttachment")
                }
            }
        }
    }

    private func iconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "md", "markdown": return "doc.text"
        case "txt": return "doc.plaintext"
        case "zip", "gz", "tar", "7z": return "archivebox"
        case "mp3", "aac", "m4a", "wav": return "music.note"
        case "mp4", "mov": return "video"
        case "xlsx", "xls": return "tablecells"
        case "docx", "doc": return "doc.richtext"
        default: return "doc"
        }
    }
}

// MARK: - Profile Share Bubble View
struct ProfileShareBubbleView: View {
    let profileData: ProfileShareData
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Avatar placeholder or image
                if let avatarData = profileData.avatarData,
                   let imageData = Data(base64Encoded: avatarData),
                   let uiImage = PlatformImage(data: imageData) {
                    Image(platformImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(AvatarStyle.squircle(AvatarStyle.bubbleSize))
                } else {
                    AvatarStyle.squircle(AvatarStyle.bubbleSize)
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .overlay(
                            Text(String(profileData.displayName.prefix(1)).uppercased())
                                .font(.title2)
                                .foregroundColor(Color.blue)
                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(profileData.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(LocalizedStringKey("shared_profile"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(16)
    }
}

// MARK: - Media Message View
struct MediaMessageView: View {
    let mediaContent: MediaMessageContent
    let message: Message
    let isSelected: Bool
    let onTapFullScreen: (() -> Void)?

    @State private var thumbnailImage: PlatformImage?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var downloadProgress: Double = 0

    /// True when this message is a local upload placeholder (not yet sent to server).
    private var isPlaceholder: Bool {
        (mediaContent.media["_placeholder"] as? Bool) == true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail — preserves natural aspect ratio, max 250×250
            if let thumbnail = thumbnailImage {
                let isUploading = isPlaceholder && message.deliveryStatus == .sending
                Image(platformImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 250, maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottom) {
                        if isUploading {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .scaleEffect(0.75)
                                    .tint(.white)
                                Text(LocalizedStringKey("uploading"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55))
                            .clipShape(Capsule())
                            .padding(.bottom, 8)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
                    .onTapGesture {
                        if !isPlaceholder { onTapFullScreen?() }
                    }
            } else if isLoading {
                // ✅ Loading state with progress indicator
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 200)
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                                .tint(Color.blue)
                            
                            if downloadProgress > 0 && downloadProgress < 1 {
                                Text("\(Int(downloadProgress * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text(LocalizedStringKey("loading"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
            } else if loadError != nil {
                // ✅ Error state with retry button
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 200)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.orange)
                            
                            Text(LocalizedStringKey("failed_to_load"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Button {
                                loadThumbnail()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text(LocalizedStringKey("retry"))
                                }
                                .font(.caption)
                                .foregroundColor(Color.blue)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            } else {
                // Placeholder - initial state
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 200)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            }
            
            // Caption if present - displayed below image without bubble
            if !mediaContent.caption.isEmpty {
                Text(mediaContent.caption)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.top, 4)
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        // Reset error state
        loadError = nil
        
        // For sender: try to load from local storage via MediaManager
        if message.isSentByMe {
            Log.debug("📱 Loading local media for sent message", category: "MediaMessage")
            if let thumbnailData = MediaManager.shared.retrieveThumbnail(for: message.id),
               let image = PlatformImage(data: thumbnailData) {
                thumbnailImage = image
                MediaImageCache.shared.store(image, for: message.id)
                Log.debug("✅ Loaded local thumbnail", category: "MediaMessage")
                return
            }
            Log.debug("⚠️ No local thumbnail found", category: "MediaMessage")
        }
        
        // For receiver: download and decrypt media (using camelCase format)
        Log.debug("📋 Media dict keys: \(Array(mediaContent.media.keys).sorted())", category: "MediaMessage")
        
        guard let mediaId = mediaContent.media["mediaId"] as? String,
              let mediaUrl = mediaContent.media["mediaUrl"] as? String,
              let mediaKeyBase64 = mediaContent.media["mediaKey"] as? String else {
            Log.error("❌ Missing media info in message. Available keys: \(mediaContent.media.keys)", category: "MediaMessage")
            loadError = "Missing media info"
            isLoading = false
            return
        }
        
        Log.debug("📥 Media info - ID: \(mediaId.prefix(8))..., URL: \(mediaUrl), Key length: \(mediaKeyBase64.count)", category: "MediaMessage")
        
        isLoading = true
        downloadProgress = 0.1
        
        Task {
            do {
                Log.info("📥 Downloading media: \(mediaId)", category: "MediaMessage")
                
                // Download and decrypt via MediaManager
                let imageData = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId,
                    mediaUrl: mediaUrl,
                    mediaKeyBase64: mediaKeyBase64
                )
                
                await MainActor.run {
                    downloadProgress = 0.9
                }
                
                guard let image = PlatformImage(data: imageData) else {
                    Log.error("❌ Failed to decode image data", category: "MediaMessage")
                    await MainActor.run {
                        isLoading = false
                        loadError = "Invalid image data"
                        downloadProgress = 0
                    }
                    return
                }
                
                // Generate thumbnail via MediaManager
                let thumbnail = MediaManager.shared.generateThumbnailImage(from: image, maxSize: 250)
                
                await MainActor.run {
                    MediaImageCache.shared.store(image, for: message.id)
                    thumbnailImage = thumbnail
                    isLoading = false
                    downloadProgress = 1.0
                    Log.info("✅ Media loaded successfully", category: "MediaMessage")
                }
                
            } catch {
                Log.error("❌ Failed to load media: \(error)", category: "MediaMessage")
                Log.error("   Error type: \(type(of: error))", category: "MediaMessage")
                if let mediaError = error as? MediaManagerError {
                    Log.error("   MediaManagerError: \(mediaError)", category: "MediaMessage")
                }
                await MainActor.run {
                    isLoading = false
                    loadError = error.localizedDescription
                    downloadProgress = 0
                }
            }
        }
    }
}
