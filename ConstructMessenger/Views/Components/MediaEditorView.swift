//
//  MediaEditorView.swift
//  Construct Messenger
//
//  Crop, rotate and mirror a picked photo before it is sent. CT chrome throughout —
//  there is no public API for the Photos app editor (`PHContentEditingController` is
//  the protocol a Photo Editing *extension* implements to be hosted by Photos, not
//  something an app can present), so this is ours.
//

#if os(iOS)
import SwiftUI
import UIKit

struct MediaEditorView: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var aspect: CropAspect = .free
    @State private var orientation: CropOrientation = .identity

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero
    @State private var minScale: CGFloat = 1

    /// The image as the turns leave it. Recomputed only when a turn is tapped, so pinching
    /// and dragging never resample.
    @State private var oriented: UIImage

    init(image: UIImage, onConfirm: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _oriented = State(initialValue: image)
    }

    var body: some View {
        GeometryReader { geo in
            let container = stageSize(in: geo.size)
            let window = CropGeometry.cropWindow(
                container: container,
                aspect: aspect,
                imageAspect: orientedAspect
            )
            let displayed = displayedSize(window: window)

            VStack(spacing: 0) {
                header
                stage(container: container, window: window, displayed: displayed)
                controls
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { reset(window: window, displayed: displayed) }
            .onChange(of: aspect) { _, _ in reset(window: window, displayed: displayed) }
            .onChange(of: orientation) { _, _ in reset(window: window, displayed: displayed) }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: CTLayout.navIconSize, weight: .medium))
                    .foregroundColor(Color.CT.text)
                    .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(NSLocalizedString("cancel", comment: ""))

            Spacer()

            Button { onConfirm(rendered()) } label: {
                Text(NSLocalizedString("done", comment: ""))
                    .font(CTFont.medium(13))
                    .tracking(2)
                    .foregroundColor(Color.CT.accent)
                    .frame(height: CTLayout.hitTarget)
                    .padding(.horizontal, CTLayout.edgePad)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 4)
    }

    private func stage(container: CGSize, window: CGSize, displayed: CGSize) -> some View {
        ZStack {
            Image(uiImage: oriented)
                .resizable()
                .scaledToFit()
                .frame(width: displayed.width * scale, height: displayed.height * scale)
                .offset(CropGeometry.clampedOffset(
                    offset, displayedImageSize: displayed, scale: scale, window: window
                ))
                .frame(width: window.width, height: window.height)
                .clipped()
                .gesture(SimultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = max(minScale, committedScale * value)
                        }
                        .onEnded { _ in
                            committedScale = scale
                            committedOffset = CropGeometry.clampedOffset(
                                offset, displayedImageSize: displayed, scale: scale, window: window
                            )
                            offset = committedOffset
                        },
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(
                                width: committedOffset.width + value.translation.width,
                                height: committedOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            committedOffset = CropGeometry.clampedOffset(
                                offset, displayedImageSize: displayed, scale: scale, window: window
                            )
                            offset = committedOffset
                        }
                ))

            CropFrame(size: window).allowsHitTesting(false)
        }
        .frame(width: container.width, height: container.height)
    }

    private var controls: some View {
        VStack(spacing: CTLayout.inlinePad) {
            HStack(spacing: CTLayout.inlinePad) {
                iconButton("rotate.left", label: "editor_rotate") { orientation.rotateClockwise() }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                           label: "editor_mirror") { orientation.mirror() }

                Rectangle()
                    .fill(Color.CT.noise)
                    .frame(width: 0.5, height: 22)
                    .padding(.horizontal, 4)

                ForEach(CropAspect.allCases) { option in
                    Button { aspect = option } label: {
                        Text(option.label)
                            .font(CTFont.regular(12))
                            .foregroundColor(aspect == option ? Color.CT.bg : Color.CT.textDim)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(
                                CTShape.badge()
                                    .fill(aspect == option ? Color.CT.accent : Color.clear)
                            )
                            .contentShape(CTShape.badge())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, CTLayout.edgePad)
        }
        .frame(height: CTLayout.controlHeight * 1.6)
    }

    private func iconButton(_ system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color.CT.text)
                .frame(width: CTLayout.hitTarget, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(label, comment: ""))
    }

    // MARK: - Geometry glue

    private var orientedAspect: CGFloat {
        let size = oriented.size
        return size.height > 0 ? size.width / size.height : 1
    }

    /// The area the crop window may occupy: the screen minus the two bars.
    private func stageSize(in total: CGSize) -> CGSize {
        CGSize(
            width: total.width - CTLayout.edgePad * 2,
            height: total.height - CTLayout.hitTarget - CTLayout.controlHeight * 1.6 - CTLayout.edgePad * 2
        )
    }

    /// The image at scale 1: exactly covering the window, so the default view is the
    /// largest crop the aspect allows.
    private func displayedSize(window: CGSize) -> CGSize {
        let a = orientedAspect
        guard window.width > 0, window.height > 0, a > 0 else { return window }
        let windowAspect = window.width / window.height
        return a > windowAspect
            ? CGSize(width: window.height * a, height: window.height)
            : CGSize(width: window.width, height: window.width / a)
    }

    private func reset(window: CGSize, displayed: CGSize) {
        oriented = image.applying(orientation)
        minScale = CropGeometry.minimumScale(displayedImageSize: displayed, window: window)
        scale = minScale
        committedScale = minScale
        offset = .zero
        committedOffset = .zero
    }

    // MARK: - Output

    private func rendered() -> UIImage {
        let base = image.applying(orientation)
        let pixels = CGSize(width: base.size.width * base.scale, height: base.size.height * base.scale)
        let window = CropGeometry.cropWindow(
            container: stageSize(in: UIScreen.main.bounds.size),
            aspect: aspect,
            imageAspect: orientedAspect
        )
        let displayed = displayedSize(window: window)
        let rect = CropGeometry.cropRect(
            imagePixelSize: pixels,
            displayedImageSize: displayed,
            scale: scale,
            offset: offset,
            window: window
        )

        // Opening the editor and pressing Done must return the picture untouched. Re-encoding
        // costs a generation for nothing, and on a transparent PNG a needless round trip is
        // the difference between a sticker and a black rectangle.
        if CropGeometry.isNoOp(cropRect: rect, imagePixelSize: pixels, orientation: orientation) {
            return image
        }
        guard let cut = base.cgImage?.cropping(to: rect) else { return base }
        return UIImage(cgImage: cut, scale: base.scale, orientation: .up)
    }
}

// MARK: - Crop frame

private struct CropFrame: View {
    let size: CGSize

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(Color.CT.text.opacity(0.9), lineWidth: 1)
                .frame(width: size.width, height: size.height)

            // Rule of thirds, drawn inside the window rather than over the whole stage.
            Path { path in
                let thirdW = size.width / 3, thirdH = size.height / 3
                for i in 1...2 {
                    path.move(to: CGPoint(x: thirdW * CGFloat(i), y: 0))
                    path.addLine(to: CGPoint(x: thirdW * CGFloat(i), y: size.height))
                    path.move(to: CGPoint(x: 0, y: thirdH * CGFloat(i)))
                    path.addLine(to: CGPoint(x: size.width, y: thirdH * CGFloat(i)))
                }
            }
            .stroke(Color.CT.text.opacity(0.22), lineWidth: 0.5)
            .frame(width: size.width, height: size.height)
        }
    }
}

// MARK: - Applying an orientation

extension UIImage {
    /// Bake accumulated turns and the mirror into pixels.
    ///
    /// `opaque = false` is load-bearing: a sticker edited on the way out must still be a
    /// sticker, and an opaque backing would flatten its transparency to black — the same
    /// defect the send path carried until 2026-08-19.
    func applying(_ orientation: CropOrientation) -> UIImage {
        guard !orientation.isIdentity, let cg = cgImage else { return self }

        let source = CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height))
        let target = orientation.apply(to: source)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: target.width / 2, y: target.height / 2)
            c.rotate(by: CGFloat(orientation.quarterTurns) * .pi / 2)
            if orientation.mirrored { c.scaleBy(x: -1, y: 1) }
            // UIKit's y axis runs down and CoreGraphics' runs up; without this the drawing
            // comes out upside down after an odd number of transforms.
            c.scaleBy(x: 1, y: -1)
            c.draw(cg, in: CGRect(
                x: -source.width / 2, y: -source.height / 2,
                width: source.width, height: source.height
            ))
        }
    }
}
#endif
