//
//  StickerPickerView.swift
//  Construct Messenger
//
//  The Stickers tab of the media picker: recents, then each installed pack, four across, then
//  the catalog — what can be installed — as rows with a cover and a Get button. A tap on a
//  sticker sends; stickers are not "add to composer" attachments and carry no caption, and the
//  sheet closes at once (decisions/stickers-fourth-picker-tab.md). A tap on Get installs in
//  place; the pack's grid appears above and the row leaves.
//

import SwiftUI

struct StickerPickerView: View {
    let library: StickerLibrary
    let onSend: (StickerReference) -> Void
    @State private var catalog = StickerCatalog()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: StickerPickerLayout.gap), count: StickerPickerLayout.columns)

    /// Catalog rows for packs the picker does not already show.
    private var available: [StickerCatalog.Summary] {
        catalog.available(excluding: library.packs.map(\.id))
    }

    var body: some View {
        Group {
            if library.isEmpty && available.isEmpty && catalog.state != .failed {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: StickerPickerLayout.sectionGap) {
                        let recent = library.sendableRecent
                        if !recent.isEmpty {
                            section(titleKey: "sticker_picker_recent", refs: recent)
                        }
                        ForEach(library.packs, id: \.id) { pack in
                            section(
                                title: pack.title,
                                refs: pack.stickers.indices.compactMap { pack.reference(at: $0) }
                            ) {
                                // Removing keeps the pack on disk for the transcript
                                // (StickerService.uninstall); it only leaves the picker.
                                Button(role: .destructive) {
                                    try? StickerService.shared.uninstall(pack.id)
                                    library.reload()
                                } label: {
                                    Label(NSLocalizedString("sticker_pack_remove", comment: ""), systemImage: "trash")
                                }
                            }
                        }
                        catalogSection
                    }
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.bottom, CTLayout.inlinePad)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { library.reload() }
        .task { await catalog.refresh() }
    }

    // MARK: - Catalog

    @ViewBuilder
    private var catalogSection: some View {
        let rows = available
        if !rows.isEmpty || catalog.state == .failed {
            VStack(alignment: .leading, spacing: CTLayout.inlinePad) {
                sectionTitle(NSLocalizedString("sticker_picker_more_packs", comment: ""))
                if catalog.state == .failed && rows.isEmpty {
                    HStack(spacing: CTLayout.inlinePad) {
                        Text(LocalizedStringKey("sticker_catalog_failed"))
                            .font(CTFont.secondary)
                            .foregroundStyle(Color.CT.textDim)
                        Spacer()
                        Button {
                            Task { await catalog.refresh() }
                        } label: {
                            Text(LocalizedStringKey("sticker_catalog_retry"))
                                .font(CTFont.bodyEmphasis)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Color.CT.accent)
                        .accessibilityIdentifier(A11y.MediaPicker.catalogRetry)
                    }
                    .padding(.vertical, StickerPickerLayout.cellPad)
                } else {
                    ForEach(rows) { summary in
                        CatalogRow(summary: summary, catalog: catalog) {
                            Task {
                                if await catalog.install(summary.id) { library.reload() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func section(titleKey: String, refs: [StickerReference]) -> some View {
        section(title: NSLocalizedString(titleKey, comment: ""), refs: refs)
    }

    private func section<Menu: View>(
        title: String,
        refs: [StickerReference],
        @ViewBuilder menu: () -> Menu = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: CTLayout.inlinePad) {
            sectionTitle(title)
                .contextMenu { menu() }
            LazyVGrid(columns: columns, spacing: StickerPickerLayout.gap) {
                ForEach(refs, id: \.self) { ref in
                    StickerCell(reference: ref, library: library) { onSend(ref) }
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(CTFont.caption)
            .foregroundStyle(Color.CT.textDim)
            .tracking(2)
    }

    private var emptyState: some View {
        VStack(spacing: CTLayout.sectionGap) {
            Spacer()
            Image(systemName: "face.smiling")
                .font(.system(size: 34))
                .foregroundStyle(Color.CT.textDim)
            Text(LocalizedStringKey("sticker_catalog_empty"))
                .font(CTFont.body)
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            #if DEBUG
            Button {
                library.installFixture()
            } label: {
                Text(LocalizedStringKey("sticker_install_fixture"))
                    .font(CTFont.bodyEmphasis)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.MediaPicker.installFixture)
            #endif
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StickerCell: View {
    let reference: StickerReference
    let library: StickerLibrary
    let onTap: () -> Void

    @State private var image: PlatformImage?

    var body: some View {
        Button(action: onTap) {
            Group {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text(reference.emoji)
                        .font(.system(size: StickerPickerLayout.fallbackEmojiSize))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .padding(StickerPickerLayout.cellPad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(reference.emoji) \(NSLocalizedString("sticker", comment: ""))"))
        .accessibilityIdentifier(A11y.MediaPicker.sticker(reference))
        .task(id: reference) {
            image = await library.thumbnail(for: reference, side: StickerPickerLayout.thumbnailSide)
        }
    }
}

/// One pack that can be installed: cover, title, publisher · count · size, and Get.
private struct CatalogRow: View {
    let summary: StickerCatalog.Summary
    let catalog: StickerCatalog
    let onInstall: () -> Void

    @State private var cover: PlatformImage?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }()

    private var installing: Bool { catalog.installing.contains(summary.id) }
    private var failed: Bool { catalog.failed.contains(summary.id) }

    var body: some View {
        HStack(spacing: CTLayout.inlinePad) {
            Group {
                if let cover {
                    Image(platformImage: cover)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.CT.bgMsg
                }
            }
            .frame(width: StickerPickerLayout.coverSide, height: StickerPickerLayout.coverSide)
            .clipShape(CTShape.card())

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(CTFont.bodyEmphasis)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
                Text(meta)
                    .font(CTFont.caption)
                    .foregroundStyle(failed ? Color.CT.danger : Color.CT.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: CTLayout.inlinePad)

            if installing {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: StickerPickerLayout.getButtonMinWidth)
            } else {
                Button(action: onInstall) {
                    Text(LocalizedStringKey(failed ? "sticker_catalog_retry" : "sticker_get"))
                        .font(CTFont.bodyEmphasis)
                        .frame(minWidth: StickerPickerLayout.getButtonMinWidth)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(Color.CT.accent)
                .accessibilityIdentifier(A11y.MediaPicker.installPack(summary.id))
            }
        }
        .padding(.vertical, StickerPickerLayout.cellPad)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.MediaPicker.catalogPack(summary.id))
        .task(id: summary.coverSHA256) {
            cover = await catalog.cover(for: summary, side: StickerPickerLayout.coverSide)
        }
    }

    private var meta: String {
        if failed { return NSLocalizedString("sticker_install_failed", comment: "") }
        let count = String(format: NSLocalizedString("sticker_pack_count", comment: ""), summary.stickerCount)
        let size = Self.sizeFormatter.string(fromByteCount: Int64(summary.totalBytes))
        return "\(summary.publisher) · \(count) · \(size)"
    }
}

enum StickerPickerLayout {
    static let columns = 4
    static let gap: CGFloat = CTLayout.inlinePad
    static let sectionGap: CGFloat = CTLayout.sectionGap
    static let cellPad: CGFloat = 6
    /// Decode target per cell, in points; the grid is a quarter of the sheet's width.
    static let thumbnailSide: CGFloat = 96
    static let fallbackEmojiSize: CGFloat = 40
    /// A catalog row's cover: the same size as a grid cell's image, so the cover reads as
    /// "one of the stickers" rather than an icon.
    static let coverSide: CGFloat = 56
    static let getButtonMinWidth: CGFloat = 44
}
