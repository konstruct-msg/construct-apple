//
//  MessageAttachmentPreviews.swift
//  Construct Messenger
//
//  Horizontal scroll strips shown above the input bar when the user has
//  selected photos or document files to attach.
//

import SwiftUI

// MARK: - Photo Preview Strip

struct MessagePhotoPreviewBar: View {
    let images: [PlatformImage]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(Rectangle())

                        Button { onRemove(index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(CTFont.regular(11))
                                .foregroundColor(Color.CT.text)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .lineLimit(1).fixedSize()
                        }
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color.CT.bgMsg)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - File Preview Strip

struct MessageFilePreviewBar: View {
    let fileURLs: [URL]
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(fileURLs.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 6) {
                        Text(asciiFileIcon(for: url.pathExtension))
                            .font(CTFont.regular(16))
                            .foregroundColor(Color.CT.accent)
                            .lineLimit(1).fixedSize()

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

                        Button { onRemove(index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(CTFont.regular(11))
                                .foregroundColor(Color.CT.textDim)
                                .lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.CT.bgMsg)
                    .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 1))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color.CT.bgMsg)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func asciiFileIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":               return "[pdf]"
        case "md", "markdown", "txt": return "[txt]"
        case "zip", "gz", "tar":  return "[zip]"
        case "mp3", "aac", "m4a", "wav": return "[♪]"
        case "mp4", "mov", "avi": return "[vid]"
        default:                  return "[doc]"
        }
    }

    @available(*, unavailable)
    private func fileIcon(for ext: String) -> String { "" }

    private func fileSize(_ url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Previews

#Preview("Photo Preview") {
    #if canImport(UIKit)
    MessagePhotoPreviewBar(
        images: [UIImage(systemName: "photo")!, UIImage(systemName: "photo.fill")!],
        onRemove: { _ in }
    )
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
}
