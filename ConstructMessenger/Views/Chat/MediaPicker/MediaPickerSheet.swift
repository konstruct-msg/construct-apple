//
//  MediaPickerSheet.swift
//  Construct Messenger
//
//  Custom media picker: CT chrome, multi-select grid, bottom quality segment +
//  confirm checkmark. Gallery / Camera / Files. No in-sheet Send / HD chrome.
//

#if os(iOS)
import SwiftUI
import Photos
import UIKit

struct MediaPickerSheet: View {
    let maxSelection: Int
    /// Confirmed selection goes to the composer (not sent immediately).
    let onConfirm: ([MediaAttachment]) -> Void
    /// Non-image / mixed document URLs from the Files tab.
    var onPickFiles: (([URL]) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var vm: MediaPickerViewModel
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var tab: PickerTab = .gallery

    @AppStorage("composer.sendOriginalPhotos") private var sendOriginal = false
    @AppStorage("composer.videoQuality") private var videoQualityRaw = VideoQuality.p1080.rawValue

    private enum PickerTab: Hashable {
        case gallery, camera, files
    }

    /// Which quality segment to show (last-selected kind wins when mixed).
    private enum QualityMode {
        case photo
        case video
    }

    init(
        maxSelection: Int = 99,
        onConfirm: @escaping ([MediaAttachment]) -> Void,
        onPickFiles: (([URL]) -> Void)? = nil
    ) {
        self.maxSelection = maxSelection
        self.onConfirm = onConfirm
        self.onPickFiles = onPickFiles
        _vm = State(initialValue: MediaPickerViewModel(maxSelection: maxSelection))
    }

    /// Back-compat init used by early call sites (Send discarded — confirm only).
    init(
        maxSelection: Int = 99,
        onSend: @escaping ([MediaAttachment]) -> Void,
        onAdd: @escaping ([MediaAttachment]) -> Void,
        onPickFiles: (([URL]) -> Void)? = nil
    ) {
        self.maxSelection = maxSelection
        // Prefer Add-to-composer semantics; ignore quick-send.
        self.onConfirm = onAdd
        self.onPickFiles = onPickFiles
        _vm = State(initialValue: MediaPickerViewModel(maxSelection: maxSelection))
        _ = onSend
    }

    private var defaultVideoQuality: VideoQuality {
        VideoQuality(rawValue: videoQualityRaw) ?? .p1080
    }

    private var qualityMode: QualityMode {
        // Last touched item drives the segment; fall back to whichever kind is selected.
        if let focused = vm.focusedItem {
            return focused.kind == .video ? .video : .photo
        }
        if vm.hasSelectedVideo, !vm.hasSelectedImage { return .video }
        if vm.hasSelectedImage, !vm.hasSelectedVideo { return .photo }
        if vm.hasSelectedVideo { return .video }
        return .photo
    }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            content
            if vm.selectionCount > 0 {
                selectionTray
            }
            bottomTabs
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .task {
            syncDefaultsIntoViewModel()
            await vm.prepare()
        }
        .onChange(of: sendOriginal) { _, on in
            vm.setPhotoHD(on)
        }
        .onChange(of: videoQualityRaw) { _, _ in
            vm.defaultVideoQuality = defaultVideoQuality
        }
        .sheet(isPresented: $showCamera) {
            CameraPickerView { image in
                let q: MediaQuality = sendOriginal ? .original : .compressed
                onConfirm([MediaAttachment(image: image, quality: q)])
                dismiss()
            }
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                onPickFiles?(urls)
                dismiss()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(vm.isExporting)
    }

    private func syncDefaultsIntoViewModel() {
        vm.setPhotoHD(sendOriginal)
        vm.defaultVideoQuality = defaultVideoQuality
    }

    // MARK: - Chrome

    private var chrome: some View {
        HStack(spacing: 12) {
            Text(NSLocalizedString("media_picker_recents", comment: "").uppercased())
                .font(CTFont.bold(13))
                .foregroundStyle(Color.CT.text)
                .tracking(2)

            Spacer()

            if vm.isExporting {
                ProgressView()
                    .tint(Color.CT.accent)
                    .scaleEffect(0.85)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.CT.textDim)
            }
            .buttonStyle(.plain)
            .disabled(vm.isExporting)
            .accessibilityLabel(Text(LocalizedStringKey("cancel")))
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch authorizationContent {
        case .needsAuth:
            permissionView
        case .denied:
            deniedView
        case .ready:
            grid
        }
    }

    private enum AuthContent { case needsAuth, denied, ready }

    private var authorizationContent: AuthContent {
        switch vm.authorization {
        case .notDetermined: return .needsAuth
        case .denied, .restricted: return .denied
        case .authorized, .limited: return .ready
        @unknown default: return .denied
        }
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(LocalizedStringKey("media_picker_allow_access"))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await vm.prepare() }
            } label: {
                Text(LocalizedStringKey("media_picker_allow_access_action"))
                    .font(CTFont.bold(13))
                    .foregroundStyle(Color.CT.bg)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.CT.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text(LocalizedStringKey("media_picker_access_denied"))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                vm.openSettings()
            } label: {
                Text(LocalizedStringKey("media_picker_open_settings"))
                    .font(CTFont.bold(13))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        Group {
            if vm.isLoadingLibrary && vm.assets.isEmpty {
                ProgressView()
                    .tint(Color.CT.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.assets.isEmpty {
                Text(LocalizedStringKey("media_picker_empty"))
                    .font(CTFont.regular(14))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 2),
                            GridItem(.flexible(), spacing: 2),
                            GridItem(.flexible(), spacing: 2)
                        ],
                        spacing: 2
                    ) {
                        ForEach(vm.assets, id: \.localIdentifier) { asset in
                            MediaPickerCell(
                                asset: asset,
                                isSelected: vm.isSelected(asset),
                                selectionIndex: vm.selectionIndex(for: asset),
                                imageManager: vm
                            ) {
                                vm.toggle(asset)
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let msg = vm.statusMessage, !msg.isEmpty {
                Text(msg)
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.danger)
                    .padding(8)
                    .background(Color.CT.bg.opacity(0.9))
            }
        }
    }

    // MARK: - Selection tray
    // [  quality segment ………………… ]  (✓)
    // Optional estimate under segment line is skipped to keep height minimal.

    private var selectionTray: some View {
        HStack(spacing: 12) {
            qualitySegment
                .frame(maxWidth: .infinity)

            Button {
                Task { await confirmSelection() }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.CT.accent)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .disabled(vm.isExporting)
            .accessibilityLabel(Text(LocalizedStringKey("media_picker_confirm")))
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, 10)
        .background(Color.CT.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.CT.noise).frame(height: 1)
        }
        .overlay {
            if vm.isExporting {
                ProgressView()
                    .tint(Color.CT.accent)
            }
        }
    }

    /// Same control family as VEIL OFF|AUTO|ON (`CTModeSelector`).
    @ViewBuilder
    private var qualitySegment: some View {
        switch qualityMode {
        case .photo:
            CTModeSelector(
                selection: Binding(
                    get: { sendOriginal ? MediaQuality.original : MediaQuality.compressed },
                    set: { q in
                        let hd = (q == .original)
                        sendOriginal = hd
                        vm.setPhotoHD(hd)
                    }
                ),
                options: [MediaQuality.compressed, .original],
                labels: [
                    .compressed: NSLocalizedString("quality_compressed", comment: ""),
                    .original: NSLocalizedString("quality_original", comment: "")
                ],
                width: nil
            )
        case .video:
            CTModeSelector(
                selection: Binding(
                    get: { vm.trayVideoQuality },
                    set: { q in
                        videoQualityRaw = q.rawValue
                        vm.setVideoQualityForAllSelected(q)
                    }
                ),
                options: VideoQuality.allCases,
                labels: [
                    .p720: NSLocalizedString("media_picker_video_720", comment: ""),
                    .p1080: NSLocalizedString("media_picker_video_1080", comment: ""),
                    .original: NSLocalizedString("quality_original", comment: "")
                ],
                width: nil
            )
        }
    }

    // MARK: - Bottom tabs

    private var bottomTabs: some View {
        HStack(spacing: 0) {
            tabButton(.gallery, titleKey: "media_picker_tab_gallery", systemImage: "photo.on.rectangle")
            tabButton(.camera, titleKey: "camera", systemImage: "camera")
            tabButton(.files, titleKey: "files", systemImage: "doc")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.CT.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.CT.noise).frame(height: 1)
        }
    }

    private func tabButton(_ tab: PickerTab, titleKey: String, systemImage: String) -> some View {
        Button {
            handleTab(tab)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                Text(LocalizedStringKey(titleKey))
                    .font(CTFont.regular(10))
            }
            .foregroundStyle(self.tab == tab ? Color.CT.accent : Color.CT.textDim)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(vm.isExporting)
    }

    private func handleTab(_ tab: PickerTab) {
        self.tab = tab
        switch tab {
        case .gallery:
            break
        case .camera:
            showCamera = true
        case .files:
            showFilePicker = true
        }
    }

    // MARK: - Actions

    private func confirmSelection() async {
        do {
            let attachments = try await vm.exportSelection()
            guard !attachments.isEmpty else { return }
            onConfirm(attachments)
            dismiss()
        } catch {
            Log.error("Media picker export: \(error)", category: "MediaPicker")
            if vm.statusMessage == nil {
                vm.statusMessage = NSLocalizedString("media_picker_export_failed", comment: "")
            }
        }
    }
}

// MARK: - Cell

private struct MediaPickerCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let selectionIndex: Int?
    let imageManager: MediaPickerViewModel
    let onTap: () -> Void

    @State private var image: UIImage?
    @State private var requestId: PHImageRequestID = PHInvalidImageRequestID

    private let thumbSide: CGFloat = 120 * UIScreen.main.scale

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color.CT.noise.opacity(0.35))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped()

            if asset.mediaType == .video {
                VStack {
                    Spacer()
                    HStack {
                        Text(formatDuration(asset.duration))
                            .font(CTFont.regular(10))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Spacer()
                    }
                    .padding(5)
                }
            }

            selectionBadge
                .padding(6)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onAppear { loadThumb() }
        .onDisappear {
            if requestId != PHInvalidImageRequestID {
                imageManager.cancelThumbnailRequest(requestId)
                requestId = PHInvalidImageRequestID
            }
        }
    }

    private var selectionBadge: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .background(
                    Circle().fill(isSelected ? Color.CT.accent : Color.black.opacity(0.25))
                )
            if let selectionIndex {
                Text("\(selectionIndex)")
                    .font(CTFont.bold(11))
                    .foregroundStyle(Color.CT.bg)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func loadThumb() {
        let size = CGSize(width: thumbSide, height: thumbSide)
        requestId = imageManager.requestThumbnail(for: asset, targetSize: size) { img in
            Task { @MainActor in
                if let img { image = img }
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}
#endif
