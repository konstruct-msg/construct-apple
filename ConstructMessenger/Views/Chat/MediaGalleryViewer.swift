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
///
/// Bounded, and that is the point. This was a plain `[String: PlatformImage]` — no limit, no
/// eviction, no memory-warning handler — so every full-resolution image ever shown stayed for the
/// life of the process. A 1440×2048 photo decodes to ~11.8 MB regardless of the 600 KB it
/// occupied on the wire, and the device log shows the consequence: footprint climbing 127 MB →
/// 447 MB across nine minutes of ordinary chatting.
///
/// `MediaManager` already learned this — its own comment says "prefer `NSCache` over a
/// `Dictionary`: it evicts under pressure and enforces `totalCostLimit`". The lesson was applied
/// in one cache and not in the one holding objects twenty times larger.
final class MediaImageCache {
    static let shared = MediaImageCache()

    /// Roughly four full-screen photos. Enough that scrolling back over a recent burst still
    /// hits, small enough that a long session cannot accumulate hundreds of megabytes.
    private static let costLimit = 48 * 1024 * 1024

    private let cache = NSCache<NSString, PlatformImage>()

    /// Not private: the compartment separation is the invariant save-to-Photos depends on, and a
    /// test needs its own instance to assert it (see MediaImageCacheCompartmentTests).
    init() {
        cache.totalCostLimit = Self.costLimit
        cache.countLimit = 24
        cache.name = "MediaImageCache"
        // A 1024px display copy is ~4 MB, so this holds a screenful and some scrollback.
        displayCache.totalCostLimit = 24 * 1024 * 1024
        displayCache.countLimit = 48
        displayCache.name = "MediaImageCache.display"
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
            self?.displayCache.removeAllObjects()
            self?.posterCache.removeAllObjects()
            Log.info("Media image caches cleared (memory warning)", category: "MediaManager")
        }
        #endif
    }

    private static func key(_ messageId: String, _ index: Int) -> NSString {
        "\(messageId)_\(index)" as NSString
    }

    /// Cost is the decoded bitmap, not the file: `NSCache` can only bound what it is told, and
    /// the file size understates a JPEG by an order of magnitude.
    private static func decodedBytes(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        let scale = image.scale
        return Int(image.size.width * scale * image.size.height * scale * 4)
        #else
        return Int(image.size.width * image.size.height * 4)
        #endif
    }

    /// Store the image at the resolution the media actually is — the decode of the real bytes.
    ///
    /// This compartment is what "save to Photos" and "share" write out, so anything smaller than
    /// the source belongs in `storeDisplay` or `storePoster`. Named `original` rather than `store`
    /// because the old neutral name is exactly how a 320px thumbnail and a 120px reply preview got
    /// in here: at the call site `store(img, …)` reads as "cache this", not "this is what the user
    /// will save". See the header of this file's `saveCurrentImage`.
    func storeOriginal(_ image: PlatformImage, for messageId: String, at index: Int = 0) {
        cache.setObject(image, forKey: Self.key(messageId, index), cost: Self.decodedBytes(image))
    }

    func original(for messageId: String, at index: Int = 0) -> PlatformImage? {
        cache.object(forKey: Self.key(messageId, index))
    }

    // MARK: - Display copies

    /// Bubble-sized decodes, kept apart from the full-resolution entries above **on purpose**.
    ///
    /// Save-to-photos and share (`MediaGalleryViewer`) read `original(for:at:)`. If a downsampled
    /// copy were stored under the same key, the user would silently save a 1024px version of
    /// their photo — a data-loss bug wearing the costume of a memory fix.
    ///
    /// That warning was written here and the bug happened anyway, three call sites over: what the
    /// comment could not do was stop `store(_:for:at:)` from reading like "cache this". Hence the
    /// rename to `storeOriginal`, and a third compartment for previews that are neither.
    private let displayCache = NSCache<NSString, PlatformImage>()

    func storeDisplay(_ image: PlatformImage, for messageId: String, at index: Int = 0) {
        displayCache.setObject(
            image, forKey: Self.key(messageId, index), cost: Self.decodedBytes(image)
        )
    }

    func displayImage(for messageId: String, at index: Int = 0) -> PlatformImage? {
        displayCache.object(forKey: Self.key(messageId, index))
    }

    // MARK: - Posters

    /// Small previews that are not the media: a reply-bar thumbnail, a video's first frame, the
    /// transmitted thumbnail painted while the real thing downloads.
    ///
    /// Third compartment rather than reusing `display`, because `display` is keyed the same and
    /// holds the bubble's ~1024px decode — a 120px reply preview written there would replace it
    /// and the bubble would paint the small one.
    private let posterCache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 120
        cache.name = "MediaImageCache.poster"
        return cache
    }()

    func storePoster(_ image: PlatformImage, for messageId: String, at index: Int = 0) {
        posterCache.setObject(
            image, forKey: Self.key(messageId, index), cost: Self.decodedBytes(image)
        )
    }

    func poster(for messageId: String, at index: Int = 0) -> PlatformImage? {
        posterCache.object(forKey: Self.key(messageId, index))
    }

    /// Anything paintable for this key, best first. For drawing only — never for save or share.
    func paintable(for messageId: String, at index: Int = 0) -> PlatformImage? {
        displayImage(for: messageId, at: index)
            ?? original(for: messageId, at: index)
            ?? poster(for: messageId, at: index)
    }

    // Legacy single-image accessors kept for callers that don't need index
    func storePoster(_ image: PlatformImage, for messageId: String) {
        storePoster(image, for: messageId, at: 0)
    }
    func paintable(for messageId: String) -> PlatformImage? { paintable(for: messageId, at: 0) }
}

@Observable
final class MediaVideoCache {
    static let shared = MediaVideoCache()
    private init() {}

    private(set) var urls: [String: URL] = [:]

    private static func key(_ messageId: String, _ index: Int) -> String { "\(messageId)_\(index)" }

    func store(_ url: URL, for messageId: String, at index: Int = 0) {
        urls[Self.key(messageId, index)] = url
    }

    func url(for messageId: String, at index: Int = 0) -> URL? {
        urls[Self.key(messageId, index)]
    }
}

// MARK: - Parse Helper

// MARK: - Gallery Presenter Token

/// Drives `fullScreenCover(item:)` / sheet from ChatView / DesktopChatView.
/// `itemIndex` is the album tile the user tapped (0 for single-image messages).
struct GalleryStartItem: Identifiable {
    /// Core Data message id of the album/bubble.
    let messageId: String
    /// Index into that message's `mediaItems` (grid tile the user tapped).
    let itemIndex: Int
    /// Unique per (message, tile) so reopening another tile of the same album re-presents.
    var id: String { "\(messageId)_\(itemIndex)" }

    init(id messageId: String, itemIndex: Int = 0) {
        self.messageId = messageId
        self.itemIndex = max(0, itemIndex)
    }
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
    let initialItemIndex: Int
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

    /// Prefer the tapped album tile; fall back to first page of that message if the index is gone.
    private static func initialEntryId(
        messageId: String,
        itemIndex: Int,
        messages: [Message]
    ) -> String {
        let preferred = "\(messageId)_\(itemIndex)"
        // Build the same id set as `entries` without storing `self` in init.
        let validIds: Set<String> = Set(messages.flatMap { msg -> [String] in
            guard let mc = parseMediaContent(from: msg.displayText), !mc.mediaItems.isEmpty else {
                return ["\(msg.id)_0"]
            }
            return mc.mediaItems.enumerated().compactMap { idx, item in
                if let mimeType = item["mediaType"] as? String,
                   !mimeType.hasPrefix("image/"), !mimeType.hasPrefix("video/") { return nil }
                return "\(msg.id)_\(idx)"
            }
        })
        if validIds.contains(preferred) { return preferred }
        if validIds.contains("\(messageId)_0") { return "\(messageId)_0" }
        return preferred
    }

    init(
        messages: [Message],
        initialMessageId: String,
        initialItemIndex: Int = 0,
        isPresented: Binding<Bool>
    ) {
        self.messages = messages
        self.initialMessageId = initialMessageId
        self.initialItemIndex = max(0, initialItemIndex)
        self._isPresented = isPresented
        self._currentEntryId = State(
            initialValue: Self.initialEntryId(
                messageId: initialMessageId,
                itemIndex: max(0, initialItemIndex),
                messages: messages
            )
        )
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
                        .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
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
                        .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                        .contentShape(Rectangle())
                        .lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, CTLayout.sectionGap)
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
              let img = MediaImageCache.shared.original(for: entry.message.id, at: entry.itemIndex) else { return }
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
              let img = MediaImageCache.shared.original(for: entry.message.id, at: entry.itemIndex) else { return }

#if canImport(UIKit)
        // iPad requires popover sourceView — see ActivityShare / Diagnostics share-logs crash.
        ActivityShare.present(items: [img])
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
        if let cached = MediaImageCache.shared.original(for: message.id, at: itemIndex) {
            image = cached
            return
        }

        isLoading = true

        // Own sends used to take a shortcut here: read the stored thumbnail and call it done, under
        // a comment claiming "full-res stored locally". It is not — `ThumbnailStore` holds a 320px
        // JPEG capped at 12 KB. So opening your own photo full-screen showed an upscaled thumbnail,
        // and because it was written into the `original` compartment, "save to Photos" and "share"
        // wrote out that 320px copy. Silent data loss on the user's own picture.
        //
        // The full plaintext is already on disk — `MediaManager.cacheSentMedia` put it there at
        // send time (uploadImage / uploadOriginalImage / uploadVideo), keyed by mediaId, and
        // `downloadAndDecryptMedia` checks memory then disk before the network. So the own-send
        // case needs no special path at all: the shared path below is a local cache hit.

        // Download using mediaItem dict (already extracted from JSON by caller); for our own sends
        // this resolves from cache without touching the network.
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
                        MediaImageCache.shared.storeOriginal(img, for: message.id, at: itemIndex)
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
            }
        )
    }

    private func load(forceRetry: Bool = false) {
        guard player == nil, !isLoading || forceRetry else { return }
        failed = false
        progress = 0

        if let cachedURL = MediaVideoCache.shared.url(for: message.id, at: itemIndex) {
            let cachedPlayer = AVPlayer(url: cachedURL)
            tempURL = cachedURL
            player = cachedPlayer
            cachedPlayer.play()
            return
        }

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
                    MediaVideoCache.shared.store(url, for: message.id, at: itemIndex)
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
    static func cacheFirstFramePoster(from url: URL, messageId: String, itemIndex: Int) async {
        let hasPoster = await MainActor.run {
            MediaImageCache.shared.poster(for: messageId, at: itemIndex) != nil
                || MediaManager.shared.retrieveThumbnail(for: messageId, at: itemIndex) != nil
        }
        if hasPoster { return }
        guard let posterData = try? await MediaOptimizer.generateVideoThumbnail(from: url),
              let poster = PlatformImage(data: posterData) else { return }
        await MainActor.run {
            MediaImageCache.shared.storePoster(poster, for: messageId, at: itemIndex)
            MediaManager.shared.storeThumbnail(posterData, for: messageId, at: itemIndex)
        }
    }
}
