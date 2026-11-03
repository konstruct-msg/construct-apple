//
//  StickerPickerView.swift
//  Construct Messenger
//
//  The Stickers tab of the media picker: "Add stickers", recents, then each installed pack, four
//  across. A tap on a sticker sends; stickers are not "add to composer" attachments and carry no
//  caption, and the sheet closes at once (decisions/stickers-fourth-picker-tab.md). "Add
//  stickers" opens `StickerPacksView`, where packs are added from the catalog and removed.
//

import SwiftUI

struct StickerPickerView: View {
    let library: StickerLibrary
    let onSend: (StickerReference) -> Void
    @State private var catalog = StickerCatalog()
    @State private var showPacks = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: StickerPickerLayout.gap), count: StickerPickerLayout.columns)

    var body: some View {
        Group {
            if library.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: StickerPickerLayout.sectionGap) {
                        addStickersButton
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
                    }
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.bottom, CTLayout.inlinePad)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { library.reload() }
        .sheet(isPresented: $showPacks, onDismiss: { library.reload() }) {
            StickerPacksView(library: library, catalog: catalog)
                .sheetNavigation()
                #if os(macOS)
                .frame(minWidth: StickerPickerLayout.packsSheetWidth, minHeight: StickerPickerLayout.packsSheetHeight)
                #endif
        }
    }

    // MARK: - Packs

    /// Opens every pack — installed and in the catalog — in one sheet.
    private var addStickersButton: some View {
        Button {
            showPacks = true
        } label: {
            Label(NSLocalizedString("sticker_packs_add", comment: ""), systemImage: "plus")
                .font(CTFont.bodyEmphasis)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(Color.CT.accent)
        .accessibilityIdentifier(A11y.MediaPicker.addStickers)
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
            StickerSectionTitle(title: title)
                .contextMenu { menu() }
            LazyVGrid(columns: columns, spacing: StickerPickerLayout.gap) {
                ForEach(refs, id: \.self) { ref in
                    StickerCell(reference: ref, library: library) { onSend(ref) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: CTLayout.sectionGap) {
            Spacer()
            Image(systemName: "face.smiling")
                .font(CTIcon.font(CTIcon.overlay, weight: .regular))
                .foregroundStyle(Color.CT.textDim)
            Text(LocalizedStringKey("sticker_catalog_empty"))
                .font(CTFont.body)
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            addStickersButton
            #if DEBUG
            Button {
                library.installFixture()
            } label: {
                Text(LocalizedStringKey("sticker_install_fixture"))
                    .font(CTFont.bodyEmphasis)
                    .foregroundStyle(Color.CT.debug)
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
    /// The packs sheet on macOS, where a sheet takes the size of its content.
    static let packsSheetWidth: CGFloat = 420
    static let packsSheetHeight: CGFloat = 480
}
