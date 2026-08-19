//
//  AttachmentReviewView.swift
//  Construct Messenger
//
//  Look at what is about to be sent, one item at a time, and change your mind about it.
//

#if os(iOS)
import SwiftUI
import UIKit

struct AttachmentReviewView: View {
    let attachments: [MediaAttachment]
    /// Index the strip was tapped on.
    let initialIndex: Int
    /// Replace the image of the attachment at an index — the edited result.
    let onEdit: (Int, UIImage) -> Void
    let onDelete: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var editing = false

    init(
        attachments: [MediaAttachment],
        initialIndex: Int,
        onEdit: @escaping (Int, UIImage) -> Void,
        onDelete: @escaping (Int) -> Void
    ) {
        self.attachments = attachments
        self.initialIndex = initialIndex
        self.onEdit = onEdit
        self.onDelete = onDelete
        _index = State(initialValue: initialIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: counter,
                showBack: true,
                backAction: { dismiss() }
            )

            TabView(selection: $index) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { i, attachment in
                    page(for: attachment).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            actions
        }
        .ctBackground()
        .fullScreenCover(isPresented: $editing) {
            if let image = current?.displayImage {
                MediaEditorView(
                    image: image,
                    onConfirm: { edited in
                        onEdit(index, edited)
                        editing = false
                    },
                    onCancel: { editing = false }
                )
            }
        }
    }

    // MARK: - Pieces

    private var current: MediaAttachment? {
        attachments.indices.contains(index) ? attachments[index] : nil
    }

    /// `3/7`, not "Photo 3 of 7": the count is the only thing that changes and a number
    /// reads the same in every locale we ship.
    private var counter: String {
        "\(index + 1)/\(attachments.count)"
    }

    @ViewBuilder
    private func page(for attachment: MediaAttachment) -> some View {
        if let image = attachment.displayImage {
            ZoomableImage(image: image)
        } else {
            Rectangle().fill(Color.CT.bgMsg)
        }
    }

    private var actions: some View {
        HStack(spacing: CTLayout.inlinePad) {
            Button {
                onDelete(index)
                // Deleting the last item empties the review — there is nothing left to look at.
                if attachments.count <= 1 {
                    dismiss()
                } else if index >= attachments.count - 1 {
                    index = max(0, index - 1)
                }
            } label: {
                Label(NSLocalizedString("delete", comment: ""), systemImage: "trash")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.danger)
                    .frame(maxWidth: .infinity)
                    .frame(height: CTLayout.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Video has no editor here — trimming is a different tool and pretending
            // otherwise would offer a button that opens a crop for a poster frame.
            if current?.kind == .image {
                Button { editing = true } label: {
                    Label(NSLocalizedString("edit", comment: ""), systemImage: "crop.rotate")
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: CTLayout.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.bottom, CTLayout.inlinePad)
    }
}

// MARK: - Pinch-to-zoom page

private struct ZoomableImage: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var committed: CGFloat = 1

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = max(1, committed * $0) }
                    .onEnded { _ in
                        // Snap back rather than leaving the page zoomed: the pager owns the
                        // horizontal drag, and a zoomed page fights it on every swipe.
                        withAnimation(.easeOut(duration: 0.2)) { scale = 1 }
                        committed = 1
                    }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}
#endif

/// `fullScreenCover(item:)` needs an `Identifiable`, and a bare `Int` is not one.
///
/// Wrapping it keeps the presentation driven by a single optional: a `Bool` plus a separate
/// index can disagree about which attachment is on screen, and the index is exactly what the
/// sheet is for.
struct AttachmentReviewTarget: Identifiable, Equatable {
    let index: Int
    var id: Int { index }
}
