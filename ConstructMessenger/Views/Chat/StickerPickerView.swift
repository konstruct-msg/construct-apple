//
//  StickerPickerView.swift
//  Construct Messenger
//
//  The Stickers tab of the media picker: recents, then each installed pack, four across.
//  A tap sends — stickers are not "add to composer" attachments and carry no caption — and the
//  sheet closes at once (decisions/stickers-fourth-picker-tab.md).
//

import SwiftUI

struct StickerPickerView: View {
    let library: StickerLibrary
    let onSend: (StickerReference) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: StickerPickerLayout.gap), count: StickerPickerLayout.columns)

    var body: some View {
        Group {
            if library.isEmpty {
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
                            )
                        }
                    }
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.bottom, CTLayout.inlinePad)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { library.reload() }
    }

    private func section(titleKey: String, refs: [StickerReference]) -> some View {
        section(title: NSLocalizedString(titleKey, comment: ""), refs: refs)
    }

    private func section(title: String, refs: [StickerReference]) -> some View {
        VStack(alignment: .leading, spacing: CTLayout.inlinePad) {
            Text(title.uppercased())
                .font(CTFont.caption)
                .foregroundStyle(Color.CT.textDim)
                .tracking(2)
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

enum StickerPickerLayout {
    static let columns = 4
    static let gap: CGFloat = CTLayout.inlinePad
    static let sectionGap: CGFloat = CTLayout.sectionGap
    static let cellPad: CGFloat = 6
    /// Decode target per cell, in points; the grid is a quarter of the sheet's width.
    static let thumbnailSide: CGFloat = 96
    static let fallbackEmojiSize: CGFloat = 40
}
