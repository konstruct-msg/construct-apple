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
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button { onRemove(index) } label: {
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

                        Button { onRemove(index) } label: {
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
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func fileIcon(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":               return "doc.richtext"
        case "md", "markdown":    return "doc.text"
        case "txt":               return "doc.text"
        case "zip", "gz", "tar":  return "archivebox"
        case "mp3", "aac", "m4a", "wav": return "music.note"
        case "mp4", "mov", "avi": return "video"
        default:                  return "doc"
        }
    }

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
