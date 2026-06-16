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
                    .font(CTFont.regular(12))
                    .foregroundColor(isSentByMe ? Color.CT.bg : Color.CT.text)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe))
        .ctNoiseBorder()
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
                .ctNoiseBorder()

                // Play / Download overlay
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 54, height: 54)
                    if downloading.contains(file.mediaId) {
                        ProgressView().tint(Color.CT.accent).scaleEffect(1.2)
                    } else {
                        // TODO: rewrite with system symbols
                        // play.circle.fill
                        // arrow.down.circle.fill
                        Text(downloadedURLs[file.mediaId] != nil ? "[▶]" : "[↓]")
                            .font(CTFont.bold(20))
                            .foregroundColor(.white)
                    }
                }

                // Duration / size badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                            .font(CTFont.regular(10))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.black.opacity(0.5))
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
                Text(asciiIcon(for: file.filename))
                    .font(CTFont.regular(20))
                    .foregroundColor(isSentByMe ? Color.CT.bg : Color.CT.accent)
                    .frame(width: 32)
                    .lineLimit(1).fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename)
                        .font(CTFont.medium(13))
                        .foregroundColor(isSentByMe ? Color.CT.bg : Color.CT.text)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .font(CTFont.regular(11))
                        .foregroundColor(isSentByMe ? Color.CT.bg.opacity(0.7) : Color.CT.textDim)
                }

                Spacer()

                if downloading.contains(file.mediaId) {
                    ProgressView()
                        .tint(isSentByMe ? Color.CT.bg : Color.CT.accent)
                        .scaleEffect(0.8)
                } else if downloadedURLs[file.mediaId] != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(CTFont.regular(13))
                        .foregroundColor(isSentByMe ? Color.CT.bg.opacity(0.8) : Color.CT.accent)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(CTFont.regular(13))
                        .foregroundColor(isSentByMe ? Color.CT.bg.opacity(0.8) : Color.CT.accent)
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
                    Log.error("File download failed: \(error)", category: "FileAttachment")
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
                    Log.error("Video download failed: \(error)", category: "FileAttachment")
                }
            }
        }
    }

    /// Shared download helper — saves decrypted data to a stable temp file.
    private func downloadFile(_ file: FileMessageContent.FileEntry) async throws -> URL {
        let data = try await MediaManager.shared.downloadAndDecryptFile(
            mediaId: file.mediaId,
            mediaUrl: file.mediaUrl,
            mediaKey: file.mediaKey,
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
            Log.debug("Video thumbnail failed: \(error)", category: "FileAttachment")
        }
    }
    #endif

    private func isVideoFile(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }
    
    // TODO: need to replace with system image icons
    private func asciiIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":                          return "[pdf]"
        case "md", "markdown", "txt":        return "[txt]"
        case "zip", "gz", "tar", "7z":       return "[zip]"
        case "mp3", "aac", "m4a", "wav":     return "[♪]"
        case "mp4", "mov", "m4v":            return "[vid]"
        case "xlsx", "xls":                  return "[xls]"
        case "docx", "doc":                  return "[doc]"
        default:                             return "[doc]"
        }
    }

    @available(*, unavailable)
    private func iconName(for filename: String) -> String { "" }
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
