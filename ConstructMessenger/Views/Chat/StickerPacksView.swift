//
//  StickerPacksView.swift
//  Construct Messenger
//
//  Every pack in one list, opened by "Add stickers" at the top of the Stickers tab: the packs in
//  the picker, each with Remove, then the server's catalog minus those, each with Get. The
//  picker itself only shows what is installed; this sheet is where a pack is added or taken out.
//
//  Get goes through `StickerCatalog.install` (whole-pack fetch, signature and hash checked);
//  Remove through `StickerService.uninstall`, which keeps the bytes for the transcript.
//

import SwiftUI

/// What a pack row's button offers. Pure, so the decision is tested apart from the view.
enum StickerPackRowAction: Equatable {
    case get
    /// An install is in flight: progress, no second tap.
    case installing
    /// The last install failed.
    case retry
    case remove

    static func of(installed: Bool, installing: Bool, failed: Bool) -> Self {
        if installed { return .remove }
        if installing { return .installing }
        return failed ? .retry : .get
    }
}

struct StickerPacksView: View {
    let library: StickerLibrary
    let catalog: StickerCatalog

    private var available: [StickerCatalog.Summary] {
        catalog.available(excluding: library.packs.map(\.id))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: StickerPickerLayout.sectionGap) {
                if !library.packs.isEmpty {
                    VStack(alignment: .leading, spacing: CTLayout.inlinePad) {
                        StickerSectionTitle(title: NSLocalizedString("sticker_packs_mine", comment: ""))
                        ForEach(library.packs, id: \.id) { pack in
                            installedRow(pack)
                        }
                    }
                }
                catalogSection
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTLayout.inlinePad)
        }
        .background(Color.CT.bg)
        .navigationTitle(NSLocalizedString("sticker_packs_title", comment: ""))
        .inlineNavTitle()
        .onAppear { library.reload() }
        .task {
            if catalog.state != .loaded { await catalog.refresh() }
        }
    }

    private func installedRow(_ pack: StickerPack) -> some View {
        StickerPackRow(
            id: pack.id,
            title: pack.title,
            publisher: pack.publisher,
            stickerCount: pack.stickers.count,
            totalBytes: nil,
            action: .remove,
            coverKey: pack.stickers.first?.sha256 ?? Data(),
            cover: { side in
                guard let ref = pack.reference(at: 0) else { return nil }
                return await library.thumbnail(for: ref, side: side)
            },
            onAction: {
                do {
                    try StickerService.shared.uninstall(pack.id)
                } catch {
                    Log.error("Sticker pack \(pack.id.hex.prefix(16))… remove failed: \(error)", category: "Stickers")
                }
                library.reload()
            }
        )
    }

    @ViewBuilder
    private var catalogSection: some View {
        let rows = available
        VStack(alignment: .leading, spacing: CTLayout.inlinePad) {
            StickerSectionTitle(title: NSLocalizedString("sticker_picker_more_packs", comment: ""))
            if !rows.isEmpty {
                ForEach(rows) { summary in
                    StickerPackRow(
                        id: summary.id,
                        title: summary.title,
                        publisher: summary.publisher,
                        stickerCount: summary.stickerCount,
                        totalBytes: summary.totalBytes,
                        action: .of(
                            installed: false,
                            installing: catalog.installing.contains(summary.id),
                            failed: catalog.failed.contains(summary.id)
                        ),
                        coverKey: summary.coverSHA256,
                        cover: { side in await catalog.cover(for: summary, side: side) },
                        onAction: {
                            Task {
                                if await catalog.install(summary.id) { library.reload() }
                            }
                        }
                    )
                }
            } else {
                switch catalog.state {
                case .failed:
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
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, StickerPickerLayout.cellPad)
                case .loaded:
                    Text(LocalizedStringKey("sticker_packs_all_added"))
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.vertical, StickerPickerLayout.cellPad)
                }
            }
        }
    }
}

/// One pack: cover, title, publisher · count (· size), and its button.
private struct StickerPackRow: View {
    let id: StickerPackID
    let title: String
    let publisher: String
    let stickerCount: Int
    /// The catalog's size; an installed pack's bytes are already on the device, so it has none.
    let totalBytes: Int?
    let action: StickerPackRowAction
    let coverKey: Data
    let cover: (CGFloat) async -> PlatformImage?
    let onAction: () -> Void

    @State private var image: PlatformImage?

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        HStack(spacing: CTLayout.inlinePad) {
            Group {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.CT.bgMsg
                }
            }
            .frame(width: StickerPickerLayout.coverSide, height: StickerPickerLayout.coverSide)
            .clipShape(CTShape.card())

            VStack(alignment: .leading, spacing: CTSpace.xs) {
                Text(title)
                    .font(CTFont.bodyEmphasis)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
                Text(meta)
                    .font(CTFont.caption)
                    .foregroundStyle(action == .retry ? Color.CT.danger : Color.CT.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: CTLayout.inlinePad)

            button
        }
        .padding(.vertical, StickerPickerLayout.cellPad)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11y.MediaPicker.catalogPack(id))
        .task(id: coverKey) {
            image = await cover(StickerPickerLayout.coverSide)
        }
    }

    @ViewBuilder
    private var button: some View {
        switch action {
        case .installing:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: StickerPickerLayout.getButtonMinWidth)
        case .get, .retry, .remove:
            Button(role: action == .remove ? .destructive : nil, action: onAction) {
                Text(LocalizedStringKey(label))
                    .font(CTFont.bodyEmphasis)
                    .frame(minWidth: StickerPickerLayout.getButtonMinWidth)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(action == .remove ? Color.CT.danger : Color.CT.accent)
            .accessibilityIdentifier(
                action == .remove ? A11y.MediaPicker.removePack(id) : A11y.MediaPicker.installPack(id)
            )
        }
    }

    private var label: String {
        switch action {
        case .remove: "sticker_packs_remove_short"
        case .retry: "sticker_catalog_retry"
        case .get, .installing: "sticker_get"
        }
    }

    private var meta: String {
        if action == .retry { return NSLocalizedString("sticker_install_failed", comment: "") }
        var parts = [publisher, String(format: NSLocalizedString("sticker_pack_count", comment: ""), stickerCount)]
        if let totalBytes { parts.append(Self.sizeFormatter.string(fromByteCount: Int64(totalBytes))) }
        return parts.joined(separator: " · ")
    }
}

/// A section header in the sticker surfaces: caption, upper-cased, tracked.
struct StickerSectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(CTFont.caption)
            .foregroundStyle(Color.CT.textDim)
            .tracking(2)
    }
}
