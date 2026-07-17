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

struct MessagePhotoPreviewBar: View {
    let images: [PlatformImage]
    let onRemove: (Int) -> Void

    private let thumbSize: CGFloat = 80

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CTLayout.inlinePad) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: thumbSize, height: thumbSize)
                            .clipShape(CTShape.card())
                            .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 0.5))

                        removeButton { onRemove(index) }
                            .offset(x: 6, y: -6)
                    }
                    .frame(width: thumbSize, height: thumbSize)
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
        images: [UIImage(systemName: "photo")!, UIImage(systemName: "photo.fill")!],
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
