//
//  StickerPackPreviewView.swift
//  Construct Messenger
//
//  A tap on a sticker in the transcript opens its pack: the title, every sticker, and Add (or
//  Remove when the pack is already in the picker). The pattern people know from Telegram. A
//  tap on a sticker here sends it to the chat the preview was opened from and closes it.
//
//  The pack is usually present already — the bubble that was tapped fetched it to render — so
//  Add only marks it installed (`StickerService.install`); no second fetch per pack.
//

import SwiftUI

/// What the preview's button offers. Pure, so the decision is tested apart from the view.
enum StickerPackPreviewAction: Equatable {
    /// The pack is being fetched.
    case loading
    case add
    case remove
    /// The fetch ended without the pack (withdrawn, unreachable, in backoff).
    case unavailable

    static func of(present: Bool, installed: Bool, fetchFinished: Bool) -> Self {
        guard present else { return fetchFinished ? .unavailable : .loading }
        return installed ? .remove : .add
    }
}

/// The sheet's item: one pack.
struct StickerPackPreviewItem: Identifiable {
    let pack: StickerPackID
    var id: String { pack.hex }
}

struct StickerPackPreviewView: View {
    let packID: StickerPackID
    /// Send a sticker from the pack to the chat behind the sheet.
    let onSend: (StickerReference) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pack: StickerPack?
    @State private var installed = false
    @State private var fetchFinished = false
    @State private var busy = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: StickerPickerLayout.gap),
        count: StickerPickerLayout.columns
    )

    private var action: StickerPackPreviewAction {
        .of(present: pack != nil, installed: installed, fetchFinished: fetchFinished)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .background(Color.CT.bg)
        .task(id: packID) { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: CTLayout.inlinePad) {
            VStack(alignment: .leading, spacing: CTSpace.xs) {
                Text(pack?.title ?? NSLocalizedString("sticker", comment: ""))
                    .font(CTFont.bodyEmphasis)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
                if let pack {
                    Text("\(pack.publisher) · \(String(format: NSLocalizedString("sticker_pack_count", comment: ""), pack.stickers.count))")
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(NSLocalizedString("done", comment: "")) { dismiss() }
                .buttonStyle(.plain)
                .font(CTFont.bodyEmphasis)
                .foregroundStyle(Color.CT.accent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, CTLayout.inlinePad)
    }

    @ViewBuilder
    private var content: some View {
        if let pack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: StickerPickerLayout.gap) {
                    ForEach(pack.stickers.indices, id: \.self) { index in
                        if let ref = pack.reference(at: index) {
                            PackStickerCell(reference: ref) {
                                dismiss()
                                onSend(ref)
                            }
                        }
                    }
                }
                .padding(CTLayout.edgePad)
            }
        } else {
            VStack {
                Spacer()
                if action == .unavailable {
                    Text(LocalizedStringKey("sticker_pack_unavailable"))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, CTLayout.edgePad)
                } else {
                    ProgressView()
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch action {
        case .add, .remove:
            Button(role: action == .remove ? .destructive : nil) {
                Task { await toggle() }
            } label: {
                Text(LocalizedStringKey(action == .remove ? "sticker_pack_remove" : "sticker_pack_add"))
                    .font(CTFont.bodyEmphasis)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(action == .remove ? Color.CT.danger : Color.CT.accent)
            .disabled(busy)
            .padding(CTLayout.edgePad)
            .accessibilityIdentifier(A11y.StickerPackPreview.toggle)
        case .loading, .unavailable:
            EmptyView()
        }
    }

    private func load() async {
        let service = StickerService.shared
        await service.ensurePresent(packID)
        pack = service.store.pack(packID)
        installed = service.store.installedPacks().contains(packID)
        fetchFinished = true
    }

    private func toggle() async {
        busy = true
        defer { busy = false }
        let service = StickerService.shared
        do {
            if installed {
                try service.uninstall(packID)
            } else {
                try await service.install(packID)
            }
            installed = service.store.installedPacks().contains(packID)
        } catch {
            Log.error("Sticker pack \(packID.hex.prefix(16))… add/remove failed: \(error)", category: "Stickers")
        }
    }
}

private struct PackStickerCell: View {
    let reference: StickerReference
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
                        .font(CTFont.ui(StickerPickerLayout.fallbackEmojiSize))
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .padding(StickerPickerLayout.cellPad)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(reference.emoji) \(NSLocalizedString("sticker", comment: ""))"))
        .task(id: reference) {
            let store = StickerService.shared.store
            image = await Task.detached(priority: .userInitiated) {
                store.blob(for: reference).flatMap(PlatformImage.init(data:))
            }.value
        }
    }
}
