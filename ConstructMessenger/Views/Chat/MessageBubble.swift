//
//  MessageBubble.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

// MARK: - Full Screen Image Viewer
struct FullScreenImageViewer: View {
    let image: UIImage
    @Binding var isPresented: Bool
    
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.8))
                            .padding()
                    }
                }
                
                Spacer()
                
                // Zoomable image
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let delta = value / lastScale
                                lastScale = value
                                scale = min(max(scale * delta, 1), 5) // Limit zoom 1x-5x
                            }
                            .onEnded { _ in
                                lastScale = 1.0
                                if scale < 1 {
                                    withAnimation(.spring()) {
                                        scale = 1
                                        offset = .zero
                                    }
                                }
                            }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1 {
                                scale = 1
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2.5
                            }
                        }
                    }
                
                Spacer()
            }
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let isLastInGroup: Bool
    let isSelected: Bool
    let isEditMode: Bool
    let onRetry: ((Message) -> Void)?
    let onReply: ((Message) -> Void)?
    let onDelete: ((Message) -> Void)?
    let onSelect: ((Message) -> Void)?
    let onEnterSelectMode: ((Message) -> Void)?

    @Environment(\.containerWidth) private var containerWidth

    init(
        message: Message,
        isLastInGroup: Bool = true,
        isSelected: Bool = false,
        isEditMode: Bool = false,
        onRetry: ((Message) -> Void)? = nil,
        onReply: ((Message) -> Void)? = nil,
        onDelete: ((Message) -> Void)? = nil,
        onSelect: ((Message) -> Void)? = nil,
        onEnterSelectMode: ((Message) -> Void)? = nil
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
    }

    var body: some View {
        // ✅ Check if this is a system message by fromUserId
        if message.fromUserId == "SYSTEM" {
            systemMessageView(message.decryptedContent ?? "System message")
        } else if let content = message.decryptedContent, content.hasPrefix("[SYSTEM]") {
            // ✅ Legacy support for [SYSTEM] prefix
            systemMessageView(content.replacingOccurrences(of: "[SYSTEM]", with: "").trimmingCharacters(in: .whitespaces))
        } else {
            regularMessageView
        }
    }
    
    // MARK: - System Message View
    private func systemMessageView(_ content: String) -> some View {
        HStack {
            Spacer()
            Text(content.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .kerning(0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
// MARK: - Regular Message View
    private var regularMessageView: some View {
        HStack(spacing: 8) {
            // Selection checkbox in edit mode
            if isEditMode && !message.isSentByMe {
                Button { onSelect?(message) } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? Color.AppBrand.second : .secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
            }

            if message.isSentByMe { Spacer(minLength: 50) }

            VStack(alignment: message.isSentByMe ? .trailing : .leading, spacing: 3) {
                // Profile share
                if let content = message.decryptedContent,
                   let profileData = parseProfileMessage(content) {
                    ProfileShareBubbleView(profileData: profileData)
                        .overlay(
                            Rectangle()
                                .strokeBorder(isSelected ? Color.AppBrand.second : Color.clear, lineWidth: 1.5)
                        )
                }
                // Media
                else if let mediaContent = parseMediaMessage(message.decryptedContent) {
                    MediaMessageView(mediaContent: mediaContent, message: message, isSelected: isSelected)
                }
                // Text message — flat rectangle
                else {
                    VStack(alignment: .leading, spacing: 0) {
                        // Reply bar
                        if let replyContent = message.replyToContent {
                            HStack(spacing: 6) {
                                Rectangle()
                                    .fill(Color.AppBrand.second)
                                    .frame(width: 2)
                                Text(replyContent)
                                    .font(.system(.caption, design: .default))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .padding(.vertical, 4)
                                    .padding(.trailing, 8)
                            }
                            .padding(.top, 4)
                        }

                        LinkDetectingText(
                            message.decryptedContent ?? NSLocalizedString("encrypted", comment: ""),
                            color: .primary
                        )
                        .padding(.horizontal, 2)
                        .padding(.vertical, message.replyToContent != nil ? 4 : 8)
                        .padding(.bottom, message.replyToContent != nil ? 8 : 0)
                    }
                    .background(isSelected ? Color.AppBrand.second.opacity(0.08) : Color.clear)
                    .overlay(
                        Group {
                            if isSelected {
                                Rectangle().strokeBorder(Color.AppBrand.second, lineWidth: 1)
                            }
                        }
                    )
                }

                // Timestamp + delivery status
                if isLastInGroup {
                    HStack(spacing: 4) {
                        if message.isSentByMe { deliveryStatusView }
                        Text(message.timestamp, style: .time)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 2)
                }
            }
            .frame(maxWidth: containerWidth * 0.72, alignment: message.isSentByMe ? .trailing : .leading)
            .contentShape(.interaction, Rectangle())
            .contentShape(.contextMenuPreview, Rectangle())
            .onTapGesture { if isEditMode { onSelect?(message) } }
            .contextMenu {
                if !isEditMode {
                    if let onReply {
                        Button { onReply(message) } label: {
                            Label("reply", systemImage: "arrowshape.turn.up.left")
                        }
                    }
                    Button { PlatformClipboard.copy(message.decryptedContent ?? "") } label: {
                        Label("copy", systemImage: "doc.on.doc")
                    }
                    if let onEnterSelectMode {
                        Button { onEnterSelectMode(message) } label: {
                            Label("select_messages", systemImage: "checkmark.circle")
                        }
                    }
                    Divider()
                    if let onDelete {
                        Button(role: .destructive) { onDelete(message) } label: {
                            Label("delete", systemImage: "trash")
                        }
                    }
                    if (message.deliveryStatus == .failed || message.deliveryStatus == .queued),
                       let onRetry {
                        Button { onRetry(message) } label: {
                            Label("retry", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }

            if !message.isSentByMe { Spacer(minLength: 50) }

            if isEditMode && message.isSentByMe {
                Button { onSelect?(message) } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundColor(isSelected ? Color.AppBrand.second : .secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var deliveryStatusView: some View {
        switch message.deliveryStatus {
        case .sending:
            Rectangle()
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                .frame(width: 8, height: 8)

        case .sent:
            Rectangle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)

        case .delivered:
            Rectangle()
                .fill(Color.AppBrand.second)
                .frame(width: 8, height: 8)

        case .queued:
            Button { onRetry?(message) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "tray")
                        .font(.system(size: 9))
                    Text("retry").font(.system(.caption2, design: .monospaced))
                }
                .foregroundColor(Color.AppBrand.third)
            }

        case .failed:
            Button { onRetry?(message) } label: {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 9, weight: .bold))
                    Text("retry").font(.system(.caption2, design: .monospaced))
                }
                .foregroundColor(Color.AppStatus.error)
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
        guard let content = content,
              let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "media",
              let mediaArray = json["media"] as? [[String: Any]],
              let firstMedia = mediaArray.first else {
            return nil
        }
        
        return MediaMessageContent(
            caption: json["caption"] as? String ?? "",
            media: firstMedia
        )
    }
}

// MARK: - Profile Share Bubble View
struct ProfileShareBubbleView: View {
    let profileData: ProfileShareData

    var body: some View {
        HStack(spacing: 12) {
            // Square avatar
            if let avatarData = profileData.avatarData,
               let imageData = Data(base64Encoded: avatarData),
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.AppBrand.second.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(String(profileData.displayName.prefix(1)).uppercased())
                            .font(.system(.headline, design: .monospaced))
                            .foregroundColor(Color.AppBrand.second)
                    )
                    .overlay(Rectangle().strokeBorder(Color.AppBrand.second.opacity(0.4), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profileData.displayName.uppercased())
                    .font(.system(.subheadline, design: .default).weight(.semibold))
                    .foregroundColor(.primary)
                Text("SHARED PROFILE")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.AppBackground.secondary)
        .overlay(Rectangle().strokeBorder(Color.AppBorder.hairline, lineWidth: 0.5))
    }
}

// MARK: - Media Message Content
struct MediaMessageContent {
    let caption: String
    let media: [String: Any]
}

// MARK: - Media Message View
struct MediaMessageView: View {
    let mediaContent: MediaMessageContent
    let message: Message
    let isSelected: Bool
    
    @State private var thumbnailImage: UIImage?
    @State private var fullImage: UIImage?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showFullScreen = false
    @State private var downloadProgress: Double = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail or placeholder - no bubble, just rounded corners
            if let thumbnail = thumbnailImage {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .aspectRatio(contentMode: .fit)
                    .clipped()
                    .overlay(
                        Rectangle()
                            .strokeBorder(isSelected ? Color.AppBrand.second : Color.AppBorder.hairline,
                                          lineWidth: isSelected ? 1.5 : 0.5)
                    )
                    .onTapGesture { showFullScreen = true }
            } else if isLoading {
                Rectangle()
                    .fill(Color.AppBackground.secondary)
                    .frame(width: 200, height: 200)
                    .overlay {
                        VStack(spacing: 10) {
                            ProgressView().tint(Color.AppBrand.second)
                            if downloadProgress > 0 && downloadProgress < 1 {
                                Text("\(Int(downloadProgress * 100))%")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Color.AppBorder.hairline, lineWidth: 0.5))
            } else if loadError != nil {
                Rectangle()
                    .fill(Color.AppBackground.secondary)
                    .frame(width: 200, height: 200)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 32))
                                .foregroundColor(Color.AppBrand.third)
                            Text("FAILED TO LOAD")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                            Button { loadThumbnail() } label: {
                                Text("RETRY")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(Color.AppBrand.second)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .overlay(Rectangle().strokeBorder(Color.AppBrand.second, lineWidth: 1))
                            }
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Color.AppBorder.hairline, lineWidth: 0.5))
            } else {
                Rectangle()
                    .fill(Color.AppBackground.secondary)
                    .frame(width: 200, height: 200)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                    }
                    .overlay(Rectangle().strokeBorder(Color.AppBorder.hairline, lineWidth: 0.5))
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
        .fullScreenCover(isPresented: $showFullScreen) {
            if let image = fullImage ?? thumbnailImage {
                FullScreenImageViewer(image: image, isPresented: $showFullScreen)
            }
        }
    }
    
    private func loadThumbnail() {
        // Reset error state
        loadError = nil
        
        // For sender: try to load from local storage via MediaManager
        if message.isSentByMe {
            Log.debug("📱 Loading local media for sent message", category: "MediaMessage")
            if let thumbnailData = MediaManager.shared.retrieveThumbnail(for: message.id),
               let image = UIImage(data: thumbnailData) {
                thumbnailImage = image
                fullImage = image
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
                    mediaUrl: mediaUrl,
                    mediaKeyBase64: mediaKeyBase64
                )
                
                await MainActor.run {
                    downloadProgress = 0.9
                }
                
                guard let image = UIImage(data: imageData) else {
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
                    fullImage = image  // Store full-res for viewer
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
