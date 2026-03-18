//
//  MediaGalleryViewer.swift
//  Construct Messenger
//

import SwiftUI
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

    func store(_ image: PlatformImage, for messageId: String) {
        images[messageId] = image
    }

    func image(for messageId: String) -> PlatformImage? {
        images[messageId]
    }
}

// MARK: - Parse Helper

// MARK: - Gallery Presenter Token

/// Drives `fullScreenCover(item:)` from ChatView.
struct GalleryStartItem: Identifiable {
    let id: String  // message.id
}

// MARK: - Gallery Viewer

struct MediaGalleryViewer: View {
    let messages: [Message]          // all media messages for this chat, ordered
    let initialMessageId: String
    @Binding var isPresented: Bool

    @State private var currentId: String
    @State private var saveStatus: SaveStatus = .idle

    enum SaveStatus { case idle, saving, saved, failed }

    @State private var dismissOffset: CGFloat = 0

    init(messages: [Message], initialMessageId: String, isPresented: Binding<Bool>) {
        self.messages = messages
        self.initialMessageId = initialMessageId
        self._isPresented = isPresented
        self._currentId = State(initialValue: initialMessageId)
    }

    private var currentIndex: Int {
        (messages.firstIndex { $0.id == currentId } ?? 0) + 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentId) {
                ForEach(messages, id: \.id) { message in
                    MediaGalleryPage(message: message)
                        .tag(message.id)
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
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()

                if messages.count > 1 {
                    Text("\(currentIndex) / \(messages.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white.opacity(0.8))
                }

                Spacer()

                Button { saveCurrentImage() } label: {
                    Image(systemName: saveStatusIcon)
                        .font(.system(size: 24))
                        .foregroundColor(saveStatusColor)
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    guard value.translation.height > 0,
                          abs(value.translation.height) > abs(value.translation.width) else { return }
                    dismissOffset = value.translation.height
                }
                .onEnded { value in
                    if dismissOffset > 100 {
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
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dismissOffset = 0
                        }
                    }
                }
        )
    }

    private var saveStatusIcon: String {
        switch saveStatus {
        case .idle:    return "square.and.arrow.down"
        case .saving:  return "arrow.down.circle"
        case .saved:   return "checkmark.circle.fill"
        case .failed:  return "exclamationmark.circle"
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
        guard let image = MediaImageCache.shared.image(for: currentId) else { return }
        saveStatus = .saving

        #if os(iOS)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            DispatchQueue.main.async {
                guard status == .authorized || status == .limited else {
                    saveStatus = .failed
                    resetSaveStatus()
                    return
                }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                saveStatus = .saved
                resetSaveStatus()
            }
        }
        #else
        if let tiffData = image.tiffRepresentation,
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
                        .simultaneousGesture(dragGesture)
                        .onTapGesture(count: 2) { toggleZoom() }
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.3))
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

    private var dragGesture: some Gesture {
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

        // Already cached — show immediately
        if let cached = MediaImageCache.shared.image(for: message.id) {
            image = cached
            return
        }

        isLoading = true

        // Sent by me — retrieve from local storage (already full-res)
        if message.isSentByMe {
            if let data = MediaManager.shared.retrieveThumbnail(for: message.id),
               let img = PlatformImage(data: data) {
                MediaImageCache.shared.store(img, for: message.id)
                image = img
            }
            isLoading = false
            return
        }

        // Received — parse metadata and download
        guard let mediaContent = parseMediaContent(from: message.decryptedContent),
              let mediaId = mediaContent.media["mediaId"] as? String,
              let mediaUrl = mediaContent.media["mediaUrl"] as? String,
              let mediaKeyBase64 = mediaContent.media["mediaKey"] as? String else {
            isLoading = false
            return
        }

        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: mediaId,
                    mediaUrl: mediaUrl,
                    mediaKeyBase64: mediaKeyBase64
                )
                if let img = PlatformImage(data: data) {
                    await MainActor.run {
                        MediaImageCache.shared.store(img, for: message.id)
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
