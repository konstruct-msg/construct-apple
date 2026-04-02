//
//  FileAttachmentBubbleView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import AVFoundation
import AVKit
import QuickLook
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct FileAttachmentBubbleView: View {
    let fileContent: FileMessageContent
    let isSentByMe: Bool

    @State private var downloadedURLs: [String: URL] = [:] // mediaId → temp file URL
    @State private var downloading: Set<String> = []
    @State private var previewURL: URL?
    @State private var videoPlayerURL: URL? // drives full-screen video player
    @State private var videoThumbnails: [String: PlatformImage] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fileContent.files, id: \.mediaId) { file in
                if isVideoFile(file.filename) {
                    videoRow(file)
                } else {
                    fileRow(file)
                }
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
        #if canImport(UIKit)
        .fullScreenCover(item: Binding(
            get: { videoPlayerURL.map { VideoPlayerItem(url: $0) } },
            set: { if $0 == nil { videoPlayerURL = nil } }
        )) { item in
            VideoPlayerView(url: item.url)
                .ignoresSafeArea()
        }
        #endif
    }

    // MARK: - Video Row

    @ViewBuilder
    private func videoRow(_ file: FileMessageContent.FileEntry) -> some View {
        Button { openOrDownloadVideo(file) } label: {
            ZStack(alignment: .center) {
                // Thumbnail or placeholder
                Group {
                    if let thumb = videoThumbnails[file.mediaId] {
                        Image(platformImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.black.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipped()
                .cornerRadius(10)

                // Play / Download overlay
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 54, height: 54)
                    if downloading.contains(file.mediaId) {
                        ProgressView().tint(.white).scaleEffect(1.2)
                    } else {
                        Image(systemName: downloadedURLs[file.mediaId] != nil ? "play.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }

                // Duration / size badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(6)
                            .padding(6)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            }
        }
        .buttonStyle(.plain)
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
                let url = try await downloadFile(file)
                await MainActor.run {
                    downloadedURLs[file.mediaId] = url
                    downloading.remove(file.mediaId)
                    previewURL = url
                }
            } catch {
                await MainActor.run {
                    downloading.remove(file.mediaId)
                    Log.error("❌ File download failed: \(error)", category: "FileAttachment")
                }
            }
        }
    }

    private func openOrDownloadVideo(_ file: FileMessageContent.FileEntry) {
        if let url = downloadedURLs[file.mediaId] {
            videoPlayerURL = url
            return
        }
        guard !downloading.contains(file.mediaId) else { return }
        downloading.insert(file.mediaId)

        Task {
            do {
                let url = try await downloadFile(file)
                await MainActor.run {
                    downloadedURLs[file.mediaId] = url
                    downloading.remove(file.mediaId)
                    videoPlayerURL = url
                }
                // Generate thumbnail in background after download
                #if canImport(UIKit)
                await generateVideoThumbnail(for: file.mediaId, url: url)
                #endif
            } catch {
                await MainActor.run {
                    downloading.remove(file.mediaId)
                    Log.error("❌ Video download failed: \(error)", category: "FileAttachment")
                }
            }
        }
    }

    /// Shared download helper — saves decrypted data to a stable temp file.
    private func downloadFile(_ file: FileMessageContent.FileEntry) async throws -> URL {
        let data = try await MediaManager.shared.downloadAndDecryptFile(
            mediaId: file.mediaId,
            mediaUrl: file.mediaUrl,
            mediaKeyBase64: file.mediaKey,
            compressed: file.compressed
        )
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(file.filename)
        try data.write(to: tmpURL)
        return tmpURL
    }

    #if canImport(UIKit)
    private func generateVideoThumbnail(for mediaId: String, url: URL) async {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 600, height: 600)
        do {
            let (cgImage, _) = try await gen.image(at: .zero)
            let thumb = UIImage(cgImage: cgImage)
            await MainActor.run { videoThumbnails[mediaId] = thumb }
        } catch {
            Log.debug("⚠️ Video thumbnail failed: \(error)", category: "FileAttachment")
        }
    }
    #endif

    private func isVideoFile(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    private func iconName(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "md", "markdown": return "doc.text"
        case "txt": return "doc.plaintext"
        case "zip", "gz", "tar", "7z": return "archivebox"
        case "mp3", "aac", "m4a", "wav": return "music.note"
        case "mp4", "mov", "m4v": return "video"
        case "xlsx", "xls": return "tablecells"
        case "docx", "doc": return "doc.richtext"
        default: return "doc"
        }
    }
}

// MARK: - Video Player Support

private struct VideoPlayerItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
private struct VideoPlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
#endif

