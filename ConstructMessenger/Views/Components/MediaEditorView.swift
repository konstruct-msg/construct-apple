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
    /// The picture exactly as it was handed in. Returned untouched when the edit is a no-op,
    /// so opening the editor and changing nothing costs no re-encode.
    private let source: UIImage
    /// The same picture with its EXIF turn baked in — every measurement below is in this one
    /// space. See `normalizedUp()` for why that matters.
    private let base: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var aspect: CropAspect = .free
    @State private var orientation: CropOrientation = .identity

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedScale: CGFloat = 1
    @State private var committedOffset: CGSize = .zero

    /// The area the crop window may occupy, as the last layout actually measured it.
    ///
    /// Held rather than re-derived on confirm: the output must be cut from the geometry the
    /// user was looking at. `rendered()` used to rebuild it from `UIScreen.main.bounds`, which
    /// is the screen including the safe areas the editor never had, so for a tall picture the
    /// crop was computed against a window that was never on screen.
    @State private var container: CGSize = .zero

    /// The image as the turns leave it. Recomputed only when a turn is tapped, so pinching
    /// and dragging never resample.
    @State private var oriented: UIImage

    init(image: UIImage, onConfirm: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        let normalized = image.normalizedUp()
        self.source = image
        self.base = normalized
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _oriented = State(initialValue: normalized)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                stage
                controls
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { container = stageSize(in: geo.size) }
            .onChange(of: geo.size) { _, new in
                container = stageSize(in: new)
                reset()
            }
            .onChange(of: aspect) { _, _ in reset() }
            .onChange(of: orientation) { _, new in
                oriented = base.applying(new)
                reset()
            }
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

    private var stage: some View {
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

    /// One derivation, read by the layout and by the output alike.
    private var window: CGSize {
        CropGeometry.cropWindow(container: container, aspect: aspect, imageAspect: orientedAspect)
    }

    private var displayed: CGSize { displayedSize(window: window) }

    /// Floor for pinch: below it the window would show empty space.
    private var minScale: CGFloat {
        CropGeometry.minimumScale(displayedImageSize: displayed, window: window)
    }

    /// Taken from the intent rather than from the rendered bitmap, so it is right on the pass
    /// where the turn has been applied but `oriented` has not caught up yet.
    private var orientedAspect: CGFloat {
        let size = orientation.apply(to: base.size)
        return size.height > 0 ? size.width / size.height : 1
    }

    /// The area the crop window may occupy: the editor's own bounds minus the two bars.
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

    /// Back to the default framing. Touches only the gesture state — the geometry it used to
    /// carry is derived from `container`, so there is nothing here that can go stale.
    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }

    // MARK: - Output

    private func rendered() -> UIImage {
        let turned = base.applying(orientation)
        let pixels = CGSize(width: turned.size.width * turned.scale,
                            height: turned.size.height * turned.scale)
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
            return source
        }
        return turned.cropped(to: rect)
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

// MARK: - One coordinate space

extension UIImage {
    /// Redraw so that `cgImage` and `size` describe the same picture.
    ///
    /// A `UIImage` carries the picture in two spaces at once: the raw `cgImage` buffer, and an
    /// `imageOrientation` saying how to turn that buffer for display. `size` is measured in the
    /// display space; `cgImage` lives in the buffer space; for anything shot on a phone the two
    /// differ by a quarter turn. Every measurement in this editor — the window, the offsets,
    /// the crop rect — is in display space, and `CGImage.cropping(to:)` reads buffer space, so
    /// handing one to the other cut the wrong region out of the wrong picture and then
    /// `UIImage(cgImage:scale:orientation: .up)` discarded the turn on the way back: a 1:1 crop
    /// of a camera photo returned rotated and looking uncropped. Rotation was unaffected and
    /// appeared to work, which is what made the report read as "cropping does not save".
    ///
    /// The space is decided once, here, on the way in. `opaque = false` keeps a sticker's
    /// transparency through the redraw.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Cut `rect` — in display-space pixels — out of the picture.
    ///
    /// Normalises first, so the rect and the buffer are measured the same way whoever calls it.
    func cropped(to rect: CGRect) -> UIImage {
        let up = normalizedUp()
        guard let cut = up.cgImage?.cropping(to: rect) else { return up }
        return UIImage(cgImage: cut, scale: up.scale, orientation: .up)
    }

    /// Bake accumulated turns and the mirror into pixels.
    ///
    /// `opaque = false` is load-bearing: a sticker edited on the way out must still be a
    /// sticker, and an opaque backing would flatten its transparency to black — the same
    /// defect the send path carried until 2026-08-19.
    func applying(_ orientation: CropOrientation) -> UIImage {
        guard !orientation.isIdentity else { return self }
        guard let cg = normalizedUp().cgImage else { return self }

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
