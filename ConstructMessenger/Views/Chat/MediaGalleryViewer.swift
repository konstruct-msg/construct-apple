//
//  MediaGalleryViewer.swift
//  Construct Messenger
//

import SwiftUI
import Combine
import AVKit
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

    /// Expand each message into per-item entries. Images and videos are shown; audio is skipped.
    private var entries: [GalleryEntry] {
        messages.flatMap { msg -> [GalleryEntry] in
            guard let mc = parseMediaContent(from: msg.displayText), !mc.mediaItems.isEmpty else {
                return [GalleryEntry(id: "\(msg.id)_0", message: msg, itemIndex: 0, mediaItem: [:])]
            }
            return mc.mediaItems.enumerated().compactMap { idx, item in
                // Show images + videos; skip audio (no visual page for it).
                if let mimeType = item["mediaType"] as? String,
                   !mimeType.hasPrefix("image/"), !mimeType.hasPrefix("video/") { return nil }
                return GalleryEntry(id: "\(msg.id)_\(idx)", message: msg, itemIndex: idx, mediaItem: item)
            }
        }.filter { !$0.mediaItem.isEmpty || parseMediaContent(from: $0.message.displayText) == nil }
    }

    private static func isVideoEntry(_ entry: GalleryEntry) -> Bool {
        (entry.mediaItem["mediaType"] as? String)?.hasPrefix("video/") == true
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
                    Group {
                        if Self.isVideoEntry(entry) {
                            GalleryVideoPage(
                                message: entry.message,
                                itemIndex: entry.itemIndex,
                                mediaItem: entry.mediaItem,
                                dismissOffset: $dismissOffset,
                                onDismiss: performDismiss
                            )
                        } else {
                            MediaGalleryPage(
                                message: entry.message,
                                itemIndex: entry.itemIndex,
                                mediaItem: entry.mediaItem,
                                dismissOffset: $dismissOffset,
                                onDismiss: performDismiss
                            )
                        }
                    }
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

                Button { shareCurrentImage() } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(CTFont.regular(20))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .lineLimit(1).fixedSize()
                }
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
              !Self.isVideoEntry(entry),
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

    private func shareCurrentImage() {
        guard let entry = entries.first(where: { $0.id == currentEntryId }),
              !Self.isVideoEntry(entry),
              let img = MediaImageCache.shared.image(for: entry.message.id, at: entry.itemIndex) else { return }

#if canImport(UIKit)
        let av = UIActivityViewController(activityItems: [img], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            var top = root
            while let presented = top.presentedViewController {
                top = presented
            }
            top.present(av, animated: true)
        }
#endif
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
                        // Vertical drag-to-dismiss (disabled while zoomed). The latched modifier
                        // avoids the old jitter where TabView reclaimed the drag mid-swipe.
                        .modifier(DragToDismiss(
                            dismissOffset: $dismissOffset,
                            isEnabled: scale <= 1.0,
                            onDismiss: onDismiss
                        ))
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

// MARK: - Drag-to-dismiss (shared)

/// Downward drag-to-dismiss for a gallery page, coexisting with the paging `TabView`.
///
/// Two things make this behave:
/// - **`.global` coordinate space.** The gallery moves its whole hierarchy by
///   `dismissOffset` while dragging. Reading `translation` in the default `.local` space
///   then measures against a view that is itself moving → a feedback loop that reads as the
///   image juddering up/down when you slow or hold the finger. Global space is fixed to the
///   screen, so translation is stable.
/// - **`minimumDistance: 20` + directional guard + `.simultaneousGesture`.** Only a clearly
///   vertical-downward drag drives dismissal; horizontal drags fall through untouched so the
///   TabView still owns paging.
private struct DragToDismiss: ViewModifier {
    @Binding var dismissOffset: CGFloat
    let isEnabled: Bool
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onChanged { value in
                    guard isEnabled,
                          value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissOffset = value.translation.height
                }
                .onEnded { _ in
                    guard isEnabled else { return }
                    if dismissOffset > 120 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dismissOffset = 0
                        }
                    }
                }
        )
    }
}

// MARK: - Gallery Video Page

/// Full-screen video playback page. Downloads + decrypts the clip to a temp file (AVPlayer
/// needs a URL), showing download progress, then autoplays with native transport controls.
struct GalleryVideoPage: View {
    let message: Message
    let itemIndex: Int
    let mediaItem: [String: Any]
    @Binding var dismissOffset: CGFloat
    let onDismiss: () -> Void

    @State private var player: AVPlayer?
    @State private var tempURL: URL?
    @State private var isLoading = false
    @State private var progress: Double = 0
    @State private var failed = false

    var body: some View {
        guard !message.isDeleted, message.managedObjectContext != nil else {
            return AnyView(Color.black)
        }
        return AnyView(
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else if failed {
                    Button { load(forceRetry: true) } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 28))
                            Text(LocalizedStringKey("retry")).font(CTFont.regular(13))
                        }
                        .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).scaleEffect(1.3)
                        if progress > 0 {
                            Text("\(Int(progress * 100))%")
                                .font(CTFont.regular(13)).foregroundColor(.white.opacity(0.8)).monospacedDigit()
                        }
                    }
                }
            }
            .modifier(DragToDismiss(dismissOffset: $dismissOffset, isEnabled: true, onDismiss: onDismiss))
            .onAppear { load() }
            .onDisappear {
                player?.pause()
                if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
            }
        )
    }

    private func load(forceRetry: Bool = false) {
        guard player == nil, !isLoading || forceRetry else { return }
        failed = false
        progress = 0

        let item = mediaItem.isEmpty
            ? (parseMediaContent(from: message.displayText)?.mediaItems.indices.contains(itemIndex) == true
               ? parseMediaContent(from: message.displayText)!.mediaItems[itemIndex]
               : [:])
            : mediaItem

        guard let mediaId = item["mediaId"] as? String,
              let mediaUrl = item["mediaUrl"] as? String,
              let mediaKeyStr = item["mediaKey"] as? String,
              let mediaKey = Data(base64Encoded: mediaKeyStr) else {
            failed = true
            return
        }
        isLoading = true

        let total = Double((item["size"] as? Int) ?? 0)
        let onProgress: @Sendable (Int64) -> Void = { received in
            guard total > 0 else { return }
            let frac = min(0.99, Double(received) / total)
            Task { @MainActor in progress = frac }
        }

        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId, mediaUrl: mediaUrl, mediaKey: mediaKey, onProgress: onProgress)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
                try data.write(to: url)
                await MainActor.run {
                    let p = AVPlayer(url: url)
                    tempURL = url
                    player = p
                    isLoading = false
                    p.play()
                }
                await Self.cacheFirstFramePoster(from: url, messageId: message.id, itemIndex: itemIndex)
            } catch {
                Log.error("Gallery video load failed: \(error)", category: "MediaGalleryViewer")
                await MainActor.run { isLoading = false; failed = true }
            }
        }
    }

    /// Derive a real first-frame poster from the downloaded clip so the bubble stops showing
    /// the blurry blurhash. Cached in-memory (live refresh) + persisted (survives relaunch).
    /// No-op if a poster already exists (e.g. the sender's own upload).
    private static func cacheFirstFramePoster(from url: URL, messageId: String, itemIndex: Int) async {
        let hasPoster = await MainActor.run {
            MediaImageCache.shared.image(for: messageId, at: itemIndex) != nil
                || MediaManager.shared.retrieveThumbnail(for: messageId, at: itemIndex) != nil
        }
        if hasPoster { return }
        guard let posterData = try? await MediaOptimizer.generateVideoThumbnail(from: url),
              let poster = PlatformImage(data: posterData) else { return }
        await MainActor.run {
            MediaImageCache.shared.store(poster, for: messageId, at: itemIndex)
            MediaManager.shared.storeThumbnail(posterData, for: messageId, at: itemIndex)
        }
    }
}
