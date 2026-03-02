//
//  ImageCropView.swift
//  Construct Messenger
//
//  Square crop editor: pan + pinch to choose which region to keep.
//

import SwiftUI

struct ImageCropView: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void
    let onCancel: () -> Void

    // Current transform state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    // Accumulated (committed) transform between gestures
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    private let cropSize: CGFloat = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * 0.82

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image layer — pannable + zoomable within the crop region
            GeometryReader { geo in
                let imageSize = fittedImageSize(in: CGSize(width: cropSize, height: cropSize))

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                    .offset(clampedOffset(imageSize: imageSize))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    scale = max(1.0, lastScale * value)
                                }
                                .onEnded { value in
                                    scale = max(1.0, lastScale * value)
                                    lastScale = scale
                                    lastOffset = clampedOffset(imageSize: imageSize)
                                    offset = lastOffset
                                },
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { value in
                                    lastOffset = clampedOffset(imageSize: imageSize)
                                    offset = lastOffset
                                }
                        )
                    )
            }
            .frame(width: cropSize, height: cropSize)
            .clipShape(Rectangle())

            // Crop overlay: dark surround + bright border square
            CropOverlayShape(cropSize: cropSize)
                .allowsHitTesting(false)

            // Controls
            VStack {
                Spacer()
                HStack {
                    Button {
                        onCancel()
                    } label: {
                        Text("cancel")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(12)
                    }

                    Button {
                        let cropped = cropImage()
                        onConfirm(cropped)
                    } label: {
                        Text("crop_use_photo")
                            .font(.headline)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear { fitImageInitially() }
    }

    // MARK: - Helpers

    /// Initial scale so the image fills the crop square
    private func fitImageInitially() {
        let imgSize = image.size
        let fillScale = max(cropSize / imgSize.width, cropSize / imgSize.height)
        scale = fillScale
        lastScale = fillScale
        offset = .zero
        lastOffset = .zero
    }

    /// Image size when fitted inside the cropSize square (scale=1 reference)
    private func fittedImageSize(in container: CGSize) -> CGSize {
        let imgSize = image.size
        let ratio = min(container.width / imgSize.width, container.height / imgSize.height)
        return CGSize(width: imgSize.width * ratio, height: imgSize.height * ratio)
    }

    /// Clamp offset so image never reveals empty space inside the crop square
    private func clampedOffset(imageSize: CGSize) -> CGSize {
        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale

        let maxX = max(0, (scaledW - cropSize) / 2)
        let maxY = max(0, (scaledH - cropSize) / 2)

        return CGSize(
            width: offset.width.clamped(to: -maxX...maxX),
            height: offset.height.clamped(to: -maxY...maxY)
        )
    }

    /// Render the visible crop square into a UIImage
    private func cropImage() -> UIImage {
        let imageSize = fittedImageSize(in: CGSize(width: cropSize, height: cropSize))
        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale

        let currentOffset = clampedOffset(imageSize: imageSize)

        // Origin of the crop square in the scaled-image coordinate space
        let originX = (scaledW - cropSize) / 2 - currentOffset.width
        let originY = (scaledH - cropSize) / 2 - currentOffset.height

        // Map back to original image pixels
        let pixelScale = image.size.width / scaledW
        let cropRect = CGRect(
            x: originX * pixelScale,
            y: originY * pixelScale,
            width: cropSize * pixelScale,
            height: cropSize * pixelScale
        )

        // Clamp to valid image bounds
        let imageBounds = CGRect(origin: .zero, size: image.size)
        let safeCrop = cropRect.intersection(imageBounds)

        guard !safeCrop.isNull,
              let cgImage = image.cgImage?.cropping(to: safeCrop) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}

// MARK: - Crop Overlay Shape

private struct CropOverlayShape: View {
    let cropSize: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dark scrim outside the crop square
                Color.black.opacity(0.55)
                    .mask(
                        Rectangle()
                            .overlay(
                                Rectangle()
                                    .frame(width: cropSize, height: cropSize)
                                    .blendMode(.destinationOut)
                            )
                            .compositingGroup()
                    )

                // Bright border
                Rectangle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: cropSize, height: cropSize)

                // Rule-of-thirds grid lines
                Path { path in
                    let x0 = (geo.size.width - cropSize) / 2
                    let y0 = (geo.size.height - cropSize) / 2
                    let third = cropSize / 3
                    // vertical lines
                    path.move(to: CGPoint(x: x0 + third, y: y0))
                    path.addLine(to: CGPoint(x: x0 + third, y: y0 + cropSize))
                    path.move(to: CGPoint(x: x0 + 2 * third, y: y0))
                    path.addLine(to: CGPoint(x: x0 + 2 * third, y: y0 + cropSize))
                    // horizontal lines
                    path.move(to: CGPoint(x: x0, y: y0 + third))
                    path.addLine(to: CGPoint(x: x0 + cropSize, y: y0 + third))
                    path.move(to: CGPoint(x: x0, y: y0 + 2 * third))
                    path.addLine(to: CGPoint(x: x0 + cropSize, y: y0 + 2 * third))
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Comparable clamping helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    ImageCropView(
        image: UIImage(systemName: "person.crop.circle.fill")!,
        onConfirm: { _ in },
        onCancel: { }
    )
}
