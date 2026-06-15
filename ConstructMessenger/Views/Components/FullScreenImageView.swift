//
//  FullScreenImageView.swift
//  Construct Messenger
//
//  Lightweight full-screen viewer for a single image (e.g. a contact's avatar):
//  pinch-zoom, pan-when-zoomed, drag-down-to-dismiss, double-tap to toggle zoom.
//  A single unified drag gesture routes by zoom state so pan and dismiss never fight.
//

import SwiftUI

struct FullScreenImageView: View {
    let image: PlatformImage
    @Binding var isPresented: Bool

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + dismissOffset)
                .gesture(magnification)
                .simultaneousGesture(drag)
                .onTapGesture(count: 2) { toggleZoom() }

            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(CTFont.regular(20))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.leading, 8)
            .padding(.top, 8)
        }
        .opacity(Double(1.0 - abs(dismissOffset) / 350))
    }

    // MARK: - Gestures

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale = min(max(scale * delta, 1.0), 5.0)
            }
            .onEnded { _ in
                lastScale = 1.0
                if scale < 1.0 { resetTransform() }
            }
    }

    /// One drag gesture: pan while zoomed, vertical drag-to-dismiss while not zoomed.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.0 {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else if value.translation.height > 0 {
                    dismissOffset = value.translation.height
                }
            }
            .onEnded { _ in
                if scale > 1.0 {
                    lastOffset = offset
                } else if dismissOffset > 100 {
                    isPresented = false
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.spring()) {
            if scale > 1.0 { resetTransform() } else { scale = 2.5 }
        }
    }

    private func resetTransform() {
        scale = 1.0
        offset = .zero
        lastOffset = .zero
    }
}
