//
//  DesktopMediaViewer.swift
//  Construct Desktop
//
//  The Mac viewer for photos and videos in a chat. The pages (`MediaGalleryPage`,
//  `GalleryVideoPage`) are the iOS ones — loading, decryption, zoom — but the frame around them
//  is not: a sized, resizable sheet, ←/→ to move, Esc to close, ⌘S to save a copy to disk
//  (`decisions/desktop-interaction-is-not-ios`: no drag-to-dismiss, no page-swipe).
//

import SwiftUI
import AppKit

struct DesktopMediaViewer: View {
    let messages: [Message]
    @Binding var isPresented: Bool

    @State private var currentId: String
    @State private var status: Status = .idle
    @FocusState private var focused: Bool

    private enum Status { case idle, saved, failed, copied }

    private static let minSize = CGSize(width: 640, height: 480)
    private static let idealSize = CGSize(width: 960, height: 700)
    private static let statusDuration: TimeInterval = 2

    init(messages: [Message], initialMessageId: String, initialItemIndex: Int, isPresented: Binding<Bool>) {
        self.messages = messages
        self._isPresented = isPresented
        self._currentId = State(
            initialValue: GalleryEntry.initialId(
                messageId: initialMessageId,
                itemIndex: initialItemIndex,
                in: messages
            )
        )
    }

    private var entries: [GalleryEntry] { GalleryEntry.expand(messages) }
    private var index: Int? { entries.firstIndex { $0.id == currentId } }
    private var current: GalleryEntry? { index.map { entries[$0] } }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black

            if let current {
                page(for: current).id(current.id)
            }

            toolbar
        }
        .frame(
            minWidth: Self.minSize.width, idealWidth: Self.idealSize.width,
            minHeight: Self.minSize.height, idealHeight: Self.idealSize.height
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onExitCommand { isPresented = false }
    }

    @ViewBuilder
    private func page(for entry: GalleryEntry) -> some View {
        // No drag-to-dismiss on the Mac: the binding is inert and `onDismiss` is never reached.
        if entry.isVideo {
            GalleryVideoPage(
                message: entry.message, itemIndex: entry.itemIndex, mediaItem: entry.mediaItem,
                dismissOffset: .constant(0), onDismiss: {}
            )
        } else {
            MediaGalleryPage(
                message: entry.message, itemIndex: entry.itemIndex, mediaItem: entry.mediaItem,
                dismissOffset: .constant(0), onDismiss: {}
            )
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: CTLayout.chromeGap) {
            Button { isPresented = false } label: { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
                .help(NSLocalizedString("close", comment: ""))

            Spacer()

            if entries.count > 1, let index {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Text("\(index + 1) / \(entries.count)")
                    .font(CTFont.mono(13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index == entries.count - 1)
            }

            Spacer()

            if let current, !current.isVideo {
                Button { copyImage(current) } label: {
                    Image(systemName: status == .copied ? "checkmark" : "doc.on.doc")
                }
                .help(NSLocalizedString("copy", comment: ""))
            }
            Button { save() } label: { Image(systemName: saveIcon) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(savableSource == nil)
                .help(NSLocalizedString("save_as", comment: ""))
        }
        .buttonStyle(.plain)
        .font(CTFont.ui(16, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, CTLayout.chromeGap)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var saveIcon: String {
        switch status {
        case .saved:  return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        default:      return "square.and.arrow.down"
        }
    }

    // MARK: - Actions

    private func step(_ delta: Int) {
        guard let index, entries.indices.contains(index + delta) else { return }
        currentId = entries[index + delta].id
    }

    /// What ⌘S would write: the decoded original for a photo, the decrypted clip for a video.
    /// Nil until the page has loaded it.
    private var savableSource: (image: NSImage?, video: URL?)? {
        guard let current else { return nil }
        if current.isVideo {
            return MediaVideoCache.shared.url(for: current.message.id, at: current.itemIndex).map { (nil, $0) }
        }
        return MediaImageCache.shared.original(for: current.message.id, at: current.itemIndex).map { ($0, nil) }
    }

    private func save() {
        guard let source = savableSource else { return }
        let outcome: MediaSaver.Outcome
        if let video = source.video {
            outcome = MediaSaver.export(fileAt: video)
        } else if let image = source.image {
            outcome = MediaSaver.export(image: image)
        } else { return }
        switch outcome {
        case .saved:     flash(.saved)
        case .failed:    flash(.failed)
        case .cancelled: break
        }
    }

    private func copyImage(_ entry: GalleryEntry) {
        guard let image = MediaImageCache.shared.original(for: entry.message.id, at: entry.itemIndex) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flash(.copied)
    }

    private func flash(_ value: Status) {
        status = value
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.statusDuration) { status = .idle }
    }
}
