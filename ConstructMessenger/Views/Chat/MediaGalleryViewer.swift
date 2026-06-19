//
//  MediaGalleryViewer.swift
//  Construct Messenger
//

import SwiftUI
import Combine
#if os(iOS)
import Photos
#else
import UniformTypeIdentifiers
#endif

// MARK: - Shared Image Cache

/// In-memory store for full-resolution images already downloaded by MediaMessageView bubbles.
/// Gallery pages check here first to avoid re-downloading.
@Observable
final class MediaImageCache {
    static let shared = MediaImageCache()
    private init() {}

    private(set) var images: [String: PlatformImage] = [:]

    private static func key(_ messageId: String, _ index: Int) -> String { "\(messageId)_\(index)" }

    func store(_ image: PlatformImage, for messageId: String, at index: Int = 0) {
        images[Self.key(messageId, index)] = image
    }

    func image(for messageId: String, at index: Int = 0) -> PlatformImage? {
        images[Self.key(messageId, index)]
    }

    // Legacy single-image accessor kept for callers that don't need index
    func store(_ image: PlatformImage, for messageId: String) { store(image, for: messageId, at: 0) }
    func image(for messageId: String) -> PlatformImage? { image(for: messageId, at: 0) }
}

// MARK: - Parse Helper

// MARK: - Gallery Presenter Token

/// Drives `fullScreenCover(item:)` from ChatView.
struct GalleryStartItem: Identifiable {
    let id: String  // message.id
}

// MARK: - Flat gallery entry (message + item index)

private struct GalleryEntry: Identifiable {
    let id: String          // "\(messageId)_\(itemIndex)"
    let message: Message
    let itemIndex: Int
    let mediaItem: [String: Any]
}

// MARK: - Gallery Viewer

struct MediaGalleryViewer: View {
    let messages: [Message]
    let initialMessageId: String
    @Binding var isPresented: Bool

    @State private var currentEntryId: String
    @State private var saveStatus: SaveStatus = .idle

    enum SaveStatus { case idle, saving, saved, failed }

    @State private var dismissOffset: CGFloat = 0

    /// Expand each message into per-item entries, skipping non-image media (video etc.)
    private var entries: [GalleryEntry] {
        messages.flatMap { msg -> [GalleryEntry] in
            guard let mc = parseMediaContent(from: msg.displayText), !mc.mediaItems.isEmpty else {
                return [GalleryEntry(id: "\(msg.id)_0", message: msg, itemIndex: 0, mediaItem: [:])]
            }
            return mc.mediaItems.enumerated().compactMap { idx, item in
                // Skip video/audio items — gallery shows images only
                if let mimeType = item["mediaType"] as? String,
                   !mimeType.hasPrefix("image/") { return nil }
                return GalleryEntry(id: "\(msg.id)_\(idx)", message: msg, itemIndex: idx, mediaItem: item)
            }
        }.filter { !$0.mediaItem.isEmpty || parseMediaContent(from: $0.message.displayText) == nil }
    }

    init(messages: [Message], initialMessageId: String, isPresented: Binding<Bool>) {
        self.messages = messages
        self.initialMessageId = initialMessageId
        self._isPresented = isPresented
        self._currentEntryId = State(initialValue: "\(initialMessageId)_0")
    }

    private var currentPosition: Int {
        (entries.firstIndex { $0.id == currentEntryId } ?? 0) + 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentEntryId) {
                ForEach(entries) { entry in
                    MediaGalleryPage(
                        message: entry.message,
                        itemIndex: entry.itemIndex,
                        mediaItem: entry.mediaItem,
                        dismissOffset: $dismissOffset,
                        onDismiss: performDismiss
                    )
                    .tag(entry.id)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
            .ignoresSafeArea()

            // Top chrome: close / counter / save
            HStack(alignment: .center) {
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(CTFont.regular(20))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .lineLimit(1).fixedSize()
                }

                Spacer()

                if entries.count > 1 {
                    Text("\(currentPosition) / \(entries.count)")
                        .font(CTFont.medium(13))
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()

                Button { saveCurrentImage() } label: {
                    Image(systemName: saveStatusIcon)
                        .font(CTFont.regular(16))
                        .foregroundColor(saveStatusColor)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .lineLimit(1).fixedSize()
                        .animation(.easeInOut(duration: 0.2), value: saveStatus)
                }
                .disabled(saveStatus == .saving)
            }
            .padding(.horizontal, 16)
            .padding(.top, 56)
            .padding(.bottom, 24)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.55), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
        .offset(y: dismissOffset)
        .opacity(Double(1.0 - dismissOffset / 350))
        // Drag-to-dismiss is driven per-page (only when not zoomed, vertical-dominant) so
        // it never competes with TabView horizontal paging or pinch-pan. See MediaGalleryPage.
    }

    /// Animate the whole gallery off-screen, then dismiss. Called by a page's
    /// drag-to-dismiss once the threshold is crossed.
    private func performDismiss() {
        withAnimation(.easeOut(duration: 0.22)) {
            #if canImport(UIKit)
            dismissOffset = UIScreen.main.bounds.height
            #else
            dismissOffset = NSScreen.main?.frame.height ?? 600
            #endif
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            isPresented = false
        }
    }
    
    private var saveStatusIcon: String {
            switch saveStatus {
            case .idle:    return "arrow.down.circle.fill"
            case .saving:  return "arrow.down.circle.fill"
            case .saved:   return "checkmark.circle.fill"
            case .failed:  return "exclamationmark.circle.fill"
            }
        }

    private var saveStatusColor: Color {
        switch saveStatus {
        case .saved:   return .green
        case .failed:  return .red
        default:       return .white.opacity(0.8)
        }
    }

    private func saveCurrentImage() {
        guard let entry = entries.first(where: { $0.id == currentEntryId }),
              let img = MediaImageCache.shared.image(for: entry.message.id, at: entry.itemIndex) else { return }
        saveStatus = .saving

        #if os(iOS)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    saveStatus = .failed
                    resetSaveStatus()
                    return
                }
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                saveStatus = .saved
                resetSaveStatus()
            }
        }
        #else
        if let tiffData = img.tiffRepresentation,
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "image.png"
            if panel.runModal() == .OK, let url = panel.url {
                try? pngData.write(to: url)
                saveStatus = .saved
            } else {
                saveStatus = .failed
            }
        } else {
            saveStatus = .failed
        }
        resetSaveStatus()
        #endif
    }

    private func resetSaveStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveStatus = .idle
        }
    }
}

// MARK: - Gallery Page

struct MediaGalleryPage: View {
    let message: Message
    let itemIndex: Int
    let mediaItem: [String: Any]
    /// Shared with the gallery container — drives the drag-to-dismiss offset/opacity.
    @Binding var dismissOffset: CGFloat
    /// Called once a downward drag crosses the dismiss threshold.
    let onDismiss: () -> Void

    @State private var image: PlatformImage?
    @State private var isLoading = false

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        guard !message.isDeleted, message.managedObjectContext != nil else {
            return AnyView(Color.black)
        }
        return AnyView(GeometryReader { geo in
            ZStack {
                Color.black

                if let img = image {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnificationGesture)
                        // Pan only exists while zoomed (mask .none disables it at scale 1),
                        // so TabView owns horizontal paging when not zoomed and the pan
                        // beats paging when zoomed.
                        .highPriorityGesture(panGesture, including: scale > 1.0 ? .all : .none)
                        // Vertical drag-to-dismiss, simultaneous so it never blocks paging;
                        // no-ops while zoomed or when the drag is horizontal-dominant.
                        .simultaneousGesture(dismissGesture)
                        .onTapGesture(count: 2) { toggleZoom() }
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                } else {
                    Text("[img]")
                        .font(CTFont.regular(28))
                        .foregroundColor(.white.opacity(0.3))
                        .lineLimit(1).fixedSize()
                }
            }
        }
        .onAppear { loadImage() }
        ) // AnyView
    }

    // MARK: Gestures

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale = min(max(scale * delta, 1.0), 5.0)
            }
            .onEnded { _ in
                lastScale = 1.0
                if scale < 1.0 { resetTransform() }
            }
    }

    /// Pan the zoomed image. Only attached (via gesture mask) while `scale > 1`.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                if scale > 1.0 {
                    lastOffset = offset
                } else {
                    offset = .zero
                    lastOffset = .zero
                }
            }
    }

    /// Downward drag-to-dismiss, active only when not zoomed and the gesture is
    /// vertical-dominant — so horizontal swipes still page the TabView.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                guard scale <= 1.0,
                      value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { _ in
                guard scale <= 1.0 else { return }
                if dismissOffset > 100 {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.spring()) {
            if scale > 1.0 { resetTransform() } else { scale = 2.5 }
        }
    }

    private func resetTransform() {
        scale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    // MARK: Loading

    private func loadImage() {
        guard !message.isDeleted, message.managedObjectContext != nil else { return }

        // Already cached
        if let cached = MediaImageCache.shared.image(for: message.id, at: itemIndex) {
            image = cached
            return
        }

        isLoading = true

        // Sent by me — full-res stored locally
        if message.isSentByMe {
            if let data = MediaManager.shared.retrieveThumbnail(for: message.id, at: itemIndex),
               let img = PlatformImage(data: data) {
                MediaImageCache.shared.store(img, for: message.id, at: itemIndex)
                image = img
            }
            isLoading = false
            return
        }

        // Received — download using mediaItem dict (already extracted from JSON by caller)
        let item = mediaItem.isEmpty
            ? (parseMediaContent(from: message.displayText)?.mediaItems.indices.contains(itemIndex) == true
               ? parseMediaContent(from: message.displayText)!.mediaItems[itemIndex]
               : [:])
            : mediaItem

        guard let mediaId = item["mediaId"] as? String,
              let mediaUrl = item["mediaUrl"] as? String,
              let mediaKeyStr = item["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr) else {
            isLoading = false
            return
        }

        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId, mediaUrl: mediaUrl, mediaKey: mediaKey)
                if let img = PlatformImage(data: data) {
                    await MainActor.run {
                        MediaImageCache.shared.store(img, for: message.id, at: itemIndex)
                        image = img
                        isLoading = false
                    }
                } else {
                    await MainActor.run { isLoading = false }
                }
            } catch {
                await MainActor.run { isLoading = false }
            }
        }
    }
}
