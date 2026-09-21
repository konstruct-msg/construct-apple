//
//  StickerBubbleView.swift
//  Construct Messenger
//
//  A sticker in the transcript. No bubble chrome — the image floats, like every messenger
//  people already know — and when the pack is not on this device the reference's emoji is
//  rendered large in its place. That is not a placeholder for a failure: the message arrived,
//  and its content is one emoji plus a reference to a pack that will be fetched.
//
//  Reads the pack store directly: a present pack's blob is a small file at a known path, and
//  the transcript renders many rows. An absent pack is asked for once — `StickerService`
//  coalesces every row's request into one fetch — and the bubble reloads when
//  `installedGeneration` advances, which is how the emoji becomes the image without a scroll.
//

import SwiftUI

struct StickerBubbleView: View {
    let reference: StickerReference
    let isSelected: Bool

    @State private var image: PlatformImage?

    private struct LoadKey: Hashable {
        let reference: StickerReference
        let generation: Int
    }

    var body: some View {
        let key = LoadKey(reference: reference, generation: StickerService.shared.installedGeneration)
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // The emoji is content, so it follows the reader's message size like text does.
                Text(reference.emoji)
                    .font(.system(size: ChatUIConstants.Sticker.fallbackEmojiSize * ChatTextPreference.sizeMultiplier))
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: ChatUIConstants.Sticker.size, height: ChatUIConstants.Sticker.size)
        .contentShape(Rectangle())
        .overlay(
            CTShape.control()
                .stroke(
                    isSelected ? Color.CT.accent : Color.clear,
                    lineWidth: ChatUIConstants.Bubble.selectionStrokeWidth
                )
        )
        .accessibilityLabel(Text("\(reference.emoji) \(NSLocalizedString("sticker", comment: ""))"))
        .accessibilityIdentifier(A11y.Chat.sticker(reference))
        .task(id: key) {
            image = await Self.load(reference)
            if image == nil, !Task.isCancelled {
                // Absent: ask once. If the pack arrives, the generation advances and this task
                // runs again with the blob on disk.
                await StickerService.shared.ensurePresent(reference.pack)
            }
        }
    }

    /// Off the main actor: a file read and a WebP decode per visible sticker row.
    private static func load(_ ref: StickerReference) async -> PlatformImage? {
        let store = await StickerService.shared.store
        return await Task.detached(priority: .userInitiated) {
            guard let data = store.blob(for: ref) else { return nil }
            return PlatformImage(data: data)
        }.value
    }
}
