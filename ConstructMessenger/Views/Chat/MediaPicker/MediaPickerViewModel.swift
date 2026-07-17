//
//  MediaPickerViewModel.swift
//  Construct Messenger
//
//  Recents library fetch, ordered multi-select, per-item quality (P2),
//  size estimates, export to MediaAttachment.
//

#if os(iOS)
import Foundation
import Photos
import UIKit
import Observation

/// One selected library asset with quality overrides (P2).
struct SelectedMediaItem: Identifiable, Equatable {
    let id: String
    let kind: MediaKind
    var imageQuality: MediaQuality
    var videoQuality: VideoQuality
    /// Best-effort original file size from Photos resources (bytes).
    var resourceByteCount: Int64?
    /// Video duration seconds (nil for images).
    var duration: TimeInterval?

    static func == (lhs: SelectedMediaItem, rhs: SelectedMediaItem) -> Bool {
        lhs.id == rhs.id
            && lhs.kind == rhs.kind
            && lhs.imageQuality == rhs.imageQuality
            && lhs.videoQuality == rhs.videoQuality
            && lhs.resourceByteCount == rhs.resourceByteCount
    }
}

@MainActor
@Observable
final class MediaPickerViewModel {

    var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var assets: [PHAsset] = []
    /// Ordered selection.
    var selection: [SelectedMediaItem] = []
    /// Last tapped selected item — drives the quality tray.
    var focusedId: String?
    var isLoadingLibrary = false
    var isExporting = false
    var statusMessage: String?

    /// Defaults for newly selected items (synced from AppStorage / HD chrome).
    var defaultImageQuality: MediaQuality = .compressed
    var defaultVideoQuality: VideoQuality = .p1080

    let maxSelection: Int
    private let imageManager = PHCachingImageManager()
    private var assetById: [String: PHAsset] = [:]

    init(maxSelection: Int = 99) {
        self.maxSelection = maxSelection
        imageManager.allowsCachingHighQualityImages = false
    }

    var selectionCount: Int { selection.count }

    var focusedItem: SelectedMediaItem? {
        guard let focusedId else { return selection.last }
        return selection.first(where: { $0.id == focusedId }) ?? selection.last
    }

    var focusedAsset: PHAsset? {
        guard let id = focusedItem?.id else { return nil }
        return assetById[id]
    }

    // MARK: - Selection queries

    func selectionIndex(for asset: PHAsset) -> Int? {
        selection.firstIndex(where: { $0.id == asset.localIdentifier }).map { $0 + 1 }
    }

    func isSelected(_ asset: PHAsset) -> Bool {
        selection.contains(where: { $0.id == asset.localIdentifier })
    }

    // MARK: - Lifecycle

    func prepare() async {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard authorization == .authorized || authorization == .limited else {
            assets = []
            return
        }
        await loadRecents()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Library

    func loadRecents() async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        options.fetchLimit = 2000

        let result = PHAsset.fetchAssets(with: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            list.append(asset)
            map[asset.localIdentifier] = asset
        }
        assets = list
        assetById = map
        selection.removeAll { map[$0.id] == nil }
        if let focusedId, map[focusedId] == nil {
            self.focusedId = selection.last?.id
        }
    }

    // MARK: - Selection

    func toggle(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if let idx = selection.firstIndex(where: { $0.id == id }) {
            selection.remove(at: idx)
            if focusedId == id {
                focusedId = selection.last?.id
            }
            return
        }
        guard selection.count < maxSelection else {
            statusMessage = NSLocalizedString("media_picker_limit_reached", comment: "")
            return
        }

        let kind: MediaKind = asset.mediaType == .video ? .video : .image
        let bytes = Self.resourceByteCount(for: asset)
        let item = SelectedMediaItem(
            id: id,
            kind: kind,
            imageQuality: defaultImageQuality,
            videoQuality: defaultVideoQuality,
            resourceByteCount: bytes,
            duration: kind == .video ? asset.duration : nil
        )
        selection.append(item)
        focusedId = id
        statusMessage = nil
    }

    func focus(_ asset: PHAsset) {
        guard isSelected(asset) else { return }
        focusedId = asset.localIdentifier
    }

    func clearSelection() {
        selection.removeAll()
        focusedId = nil
    }

    func setVideoQuality(_ quality: VideoQuality, for id: String) {
        guard let idx = selection.firstIndex(where: { $0.id == id }) else { return }
        selection[idx].videoQuality = quality
        focusedId = id
        defaultVideoQuality = quality
    }

    /// Apply video quality to every selected video (compact tray control).
    func setVideoQualityForAllSelected(_ quality: VideoQuality) {
        defaultVideoQuality = quality
        for i in selection.indices where selection[i].kind == .video {
            selection[i].videoQuality = quality
        }
    }

    /// HD is the only photo quality control: default + every selected image.
    func setPhotoHD(_ enabled: Bool) {
        let quality: MediaQuality = enabled ? .original : .compressed
        defaultImageQuality = quality
        for i in selection.indices where selection[i].kind == .image {
            selection[i].imageQuality = quality
        }
    }

    var hasSelectedVideo: Bool {
        selection.contains { $0.kind == .video }
    }

    var hasSelectedImage: Bool {
        selection.contains { $0.kind == .image }
    }

    /// Representative video quality for the tray menu (focused video, else first video).
    var trayVideoQuality: VideoQuality {
        if let focused = focusedItem, focused.kind == .video {
            return focused.videoQuality
        }
        return selection.first(where: { $0.kind == .video })?.videoQuality ?? defaultVideoQuality
    }

    // MARK: - Size estimates

    /// Estimated upload payload for the whole selection (heuristic).
    var estimatedTotalBytes: Int64 {
        selection.reduce(0) { $0 + estimatedBytes(for: $1) }
    }

    func estimatedBytes(for item: SelectedMediaItem) -> Int64 {
        switch item.kind {
        case .image:
            let raw = item.resourceByteCount ?? 2_000_000
            switch item.imageQuality {
            case .original:
                return raw
            case .compressed:
                // JPEG re-encode ≈ 15–35% of HEIC/PNG originals; floor for tiny assets.
                return max(80_000, Int64(Double(raw) * 0.22))
            }
        case .video:
            let duration = max(item.duration ?? 1, 1)
            let raw = item.resourceByteCount
            switch item.videoQuality {
            case .original:
                return raw ?? Int64(duration * 4_000_000) // ~4 MB/s fallback
            case .p1080:
                return Int64(duration * 2_500_000) // ~2.5 MB/s heuristic
            case .p720:
                return Int64(duration * 1_200_000)
            }
        }
    }

    var estimatedTotalLabel: String {
        ByteCountFormatter.string(fromByteCount: estimatedTotalBytes, countStyle: .file)
    }

    func estimatedLabel(for item: SelectedMediaItem) -> String {
        ByteCountFormatter.string(fromByteCount: estimatedBytes(for: item), countStyle: .file)
    }

    private static func resourceByteCount(for asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the primary photo/video resource.
        let preferred = resources.first(where: {
            $0.type == .photo || $0.type == .fullSizePhoto
                || $0.type == .video || $0.type == .fullSizeVideo
        }) ?? resources.first
        guard let preferred else { return nil }
        if let n = preferred.value(forKey: "fileSize") as? CLong {
            return Int64(n)
        }
        if let n = preferred.value(forKey: "fileSize") as? Int64 {
            return n
        }
        if let n = preferred.value(forKey: "fileSize") as? NSNumber {
            return n.int64Value
        }
        return nil
    }

    // MARK: - Thumbnails

    func requestThumbnail(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: opts
        ) { image, info in
            if (info?[PHImageCancelledKey] as? Bool) == true { return }
            completion(image)
        }
    }

    func cancelThumbnailRequest(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }

    // MARK: - Export

    /// Builds attachments using **per-item** quality (P2).
    func exportSelection() async throws -> [MediaAttachment] {
        guard !selection.isEmpty else { return [] }
        isExporting = true
        statusMessage = nil
        defer { isExporting = false }

        var result: [MediaAttachment] = []
        result.reserveCapacity(selection.count)

        for item in selection {
            guard let asset = assetById[item.id] else { continue }
            do {
                if item.kind == .video {
                    let exported = try await MediaAssetExporter.exportVideo(asset: asset)
                    result.append(
                        MediaAttachment(
                            videoURL: exported.url,
                            poster: exported.poster,
                            duration: exported.duration,
                            videoQuality: item.videoQuality
                        )
                    )
                } else {
                    let exported = try await MediaAssetExporter.exportImage(asset: asset)
                    result.append(
                        MediaAttachment(
                            originalData: exported.data,
                            mimeType: exported.mimeType,
                            displayImage: exported.display,
                            quality: item.imageQuality
                        )
                    )
                }
            } catch MediaAssetExportError.tooLarge {
                Log.error("Asset too large: \(item.id.prefix(8))…", category: "MediaPicker")
                statusMessage = NSLocalizedString("media_picker_item_too_large", comment: "")
            } catch {
                Log.error("Export failed \(item.id.prefix(8))…: \(error)", category: "MediaPicker")
                statusMessage = NSLocalizedString("media_picker_export_failed", comment: "")
            }
        }

        if result.isEmpty, !selection.isEmpty {
            throw MediaAssetExportError.exportFailed(statusMessage ?? "export empty")
        }
        return result
    }
}

#endif
