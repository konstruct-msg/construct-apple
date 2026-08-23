//
//  MessageAttachmentPreviews.swift
//  Construct Messenger
//
//  Horizontal scroll strips shown above the input bar when the user has
//  selected photos or document files to attach.
//

import SwiftUI
import Combine

// MARK: - Photo Preview Strip

/// The strip takes attachments, not images.
///
/// It used to take `[PlatformImage]` built as `selectedAttachments.compactMap { $0.displayImage }`,
/// and every index it handed back — remove, reorder, open — was an index into that compacted
/// array, while every handler read `selectedAttachments`. One attachment without a poster and the
/// two disagree from that point on: Delete removes a neighbour, the editor opens the wrong photo.
/// Nothing reported it, because both arrays are the same length in the case anyone tests.
///
/// The old defence was upstream — `loadVideoAttachment` synthesised a placeholder poster so the
/// arrays could not diverge. That is one producer promising something on behalf of a consumer it
/// cannot see, and `videoPlaceholderPoster()` is itself optional. Here the cell that has no image
/// draws a placeholder and keeps its slot, so the indices are the same indices by construction.
struct MessagePhotoPreviewBar: View {
    let attachments: [MediaAttachment]
    let onRemove: (Int) -> Void
    /// Long-press then drag to reorder. Album order is the order they arrive in, so this is
    /// the only place the sender can choose it — after confirming the picker and before
    /// sending. Optional so the existing call sites that cannot reorder stay honest: a strip
    /// without a handler does not offer the gesture at all, rather than offering one that
    /// silently does nothing.
    var onMove: ((Int, Int) -> Void)? = nil
    /// Tap to inspect a single item full-size.
    var onOpen: ((Int) -> Void)? = nil

    @State private var draggingIndex: Int?

    private let thumbSize: CGFloat = 80

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CTLayout.inlinePad) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    ZStack(alignment: .topTrailing) {
                        thumb(for: attachment)
                            .frame(width: thumbSize, height: thumbSize)
                            .clipShape(CTShape.card())
                            .overlay(CTShape.card().stroke(
                                draggingIndex == index ? Color.CT.accent : Color.CT.noise,
                                lineWidth: draggingIndex == index ? 1.5 : 0.5
                            ))
                            .contentShape(CTShape.card())
                            .onTapGesture { onOpen?(index) }

                        removeButton { onRemove(index) }
                            .offset(x: 6, y: -6)
                    }
                    .frame(width: thumbSize, height: thumbSize)
                    // Lifted item rides above its neighbours and shrinks slightly, so the gap
                    // it will drop into stays readable.
                    .scaleEffect(draggingIndex == index ? 0.92 : 1)
                    .zIndex(draggingIndex == index ? 1 : 0)
                    .animation(.easeInOut(duration: 0.18), value: draggingIndex)
                    .modifier(ReorderableThumb(
                        index: index,
                        enabled: onMove != nil && attachments.count > 1,
                        draggingIndex: $draggingIndex,
                        onMove: onMove
                    ))
                }
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTLayout.inlinePad)
        }
        .background(.ultraThinMaterial)
        .clipShape(CTShape.control())
        .overlay(CTShape.control().stroke(Color.CT.noise.opacity(0.5), lineWidth: 0.5))
        .padding(.horizontal, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// A cell with no image is still a cell. Losing it is what put the indices out of step.
    @ViewBuilder
    private func thumb(for attachment: MediaAttachment) -> some View {
        if let image = attachment.displayImage {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.CT.bgMsg
                Image(systemName: attachment.kind == .video ? "film" : "photo")
                    .font(.system(size: CTLayout.navIconSize, weight: .regular))
                    .foregroundColor(Color.CT.textDim)
            }
        }
    }
}

// MARK: - Reorder gesture

/// Long-press to lift, drag to move, release to drop.
///
/// `.onDrag`/`.onDrop` was the other option and is wrong here: it routes through
/// `NSItemProvider` and the system drag session, which on iPhone means a lift delay we do not
/// control, a system drag preview that ignores the CT chrome, and item identity carried as a
/// serialised payload — for a strip of at most a handful of local thumbnails that is a lot of
/// machinery to move an index. This is a plain gesture over a known geometry.
private struct ReorderableThumb: ViewModifier {
    let index: Int
    let enabled: Bool
    @Binding var draggingIndex: Int?
    let onMove: ((Int, Int) -> Void)?

    /// Thumb width plus the gap between thumbs — one "slot" of travel.
    private static let slot: CGFloat = 80 + CTLayout.inlinePad

    @State private var translation: CGFloat = 0

    func body(content: Content) -> some View {
        guard enabled else { return AnyView(content) }
        return AnyView(
            content
                .offset(x: draggingIndex == index ? translation : 0)
                .gesture(
                    LongPressGesture(minimumDuration: 0.28)
                        .onEnded { _ in
                            draggingIndex = index
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            #endif
                        }
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            // `.second(_, drag)` only carries a drag once the press has won,
                            // so a plain scroll never enters this branch.
                            if case .second(true, let drag?) = value, draggingIndex == index {
                                translation = drag.translation.width
                            }
                        }
                        .onEnded { _ in
                            defer {
                                draggingIndex = nil
                                translation = 0
                            }
                            guard draggingIndex == index else { return }
                            let steps = Int((translation / Self.slot).rounded())
                            guard steps != 0 else { return }
                            onMove?(index, index + steps)
                        }
                )
        )
    }
}

// MARK: - File Preview Strip

struct MessageFilePreviewBar: View {
    let fileURLs: [URL]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CTLayout.inlinePad) {
                ForEach(Array(fileURLs.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: CTLayout.inlinePad) {
                        Image(systemName: fileSystemIcon(for: url.pathExtension))
                            .font(.system(size: CTLayout.navIconSize, weight: .medium))
                            .foregroundColor(Color.CT.accent)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(CTFont.regular(11))
                                .foregroundColor(Color.CT.text)
                                .lineLimit(1)
                            if let size = fileSize(url) {
                                Text(size)
                                    .font(CTFont.regular(10))
                                    .foregroundColor(Color.CT.textDim)
                            }
                        }

                        removeButton { onRemove(index) }
                    }
                    .padding(.leading, CTLayout.edgePad)
                    .padding(.trailing, CTLayout.inlinePad)
                    .padding(.vertical, CTLayout.inlinePad)
                    .background(Color.CT.bgMsg)
                    .clipShape(CTShape.card())
                    .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTLayout.inlinePad)
        }
        .background(.ultraThinMaterial)
        .clipShape(CTShape.control())
        .overlay(CTShape.control().stroke(Color.CT.noise.opacity(0.5), lineWidth: 0.5))
        .padding(.horizontal, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func fileSystemIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":
            return "doc.richtext"
        case "md", "markdown", "txt", "rtf":
            return "doc.text"
        case "zip", "gz", "tar", "7z":
            return "doc.zipper"
        case "mp3", "aac", "m4a", "wav", "flac":
            return "waveform"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        case "png", "jpg", "jpeg", "heic", "gif", "webp":
            return "photo"
        default:
            return "doc"
        }
    }

    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Remove control

private func removeButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 18, weight: .regular))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.CT.text, Color.CT.bgMsg.opacity(0.92))
            .frame(width: CTLayout.hitTarget * 0.7, height: CTLayout.hitTarget * 0.7)
            .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(NSLocalizedString("close", comment: ""))
}

// MARK: - Previews

#Preview("Photo Preview") {
    #if canImport(UIKit)
    MessagePhotoPreviewBar(
        attachments: [
            MediaAttachment(image: UIImage(systemName: "photo")!),
            // No poster — the cell keeps its slot rather than vanishing from the strip.
            MediaAttachment(videoURL: URL(fileURLWithPath: "/tmp/clip.mp4"), poster: nil, duration: 3)
        ],
        onRemove: { _ in }
    )
    .padding()
    .ctBackground()
    #else
    Text("iOS only")
    #endif
}

#Preview("File Preview") {
    MessageFilePreviewBar(
        fileURLs: [
            URL(fileURLWithPath: "/tmp/document.pdf"),
            URL(fileURLWithPath: "/tmp/archive.zip")
        ],
        onRemove: { _ in }
    )
    .padding()
    .ctBackground()
}
