//
//  ImageHelper.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import UIKit

struct ImageHelper {
    // MARK: - Avatar Processing

    /// Maximum avatar size in pixels (both width and height)
    static let maxAvatarSize: CGFloat = 1024

    /// JPEG compression quality for avatars (0.0 - 1.0)
    static let avatarCompressionQuality: CGFloat = 0.7

    /// Maximum file size for avatar in bytes (256 KB)
    static let maxAvatarFileSize: Int = 256 * 1024

    /// Prepares an image for use as an avatar
    /// - Parameter image: Original UIImage
    /// - Returns: Compressed Data suitable for storage/transmission, or nil if processing failed
    static func prepareAvatarImage(_ image: UIImage) -> Data? {
        // 1. Resize to square with max dimensions
        guard let resizedImage = resizeAndCropToSquare(image, size: maxAvatarSize) else {
            return nil
        }

        // 2. Compress to JPEG
        guard var imageData = resizedImage.jpegData(compressionQuality: avatarCompressionQuality) else {
            return nil
        }

        // 3. If still too large, compress further
        var quality = avatarCompressionQuality
        while imageData.count > maxAvatarFileSize && quality > 0.1 {
            quality -= 0.1
            if let compressedData = resizedImage.jpegData(compressionQuality: quality) {
                imageData = compressedData
            } else {
                break
            }
        }

        // 4. Final check
        guard imageData.count <= maxAvatarFileSize else {
            print("⚠️ Avatar image still too large after compression: \(imageData.count) bytes")
            return nil
        }

        print("✅ Avatar prepared: \(imageData.count) bytes")
        return imageData
    }

    /// Converts Data back to UIImage
    /// - Parameter data: Image data
    /// - Returns: UIImage or nil if conversion failed
    static func imageFromData(_ data: Data?) -> UIImage? {
        guard let data = data else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Image Manipulation

    /// Resizes and crops image to a square
    /// - Parameters:
    ///   - image: Original image
    ///   - size: Target size (width and height will be equal)
    /// - Returns: Resized square image
    private static func resizeAndCropToSquare(_ image: UIImage, size: CGFloat) -> UIImage? {
        let originalSize = image.size
        let scale = max(size / originalSize.width, size / originalSize.height)

        // Calculate new size maintaining aspect ratio
        let scaledWidth = originalSize.width * scale
        let scaledHeight = originalSize.height * scale

        // Calculate crop rect (center crop)
        let cropX = (scaledWidth - size) / 2
        let cropY = (scaledHeight - size) / 2
        _ = CGRect(x: cropX, y: cropY, width: size, height: size)

        // Render
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // We want exact pixels
        format.opaque = true // Avatars don't need transparency

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)

        return renderer.image { context in
            // Fill background (in case of transparency)
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: size, height: size)))

            // Draw scaled image
            let drawRect = CGRect(x: -cropX, y: -cropY, width: scaledWidth, height: scaledHeight)
            image.draw(in: drawRect)
        }
    }

    /// Creates a placeholder avatar with initials
    /// - Parameters:
    ///   - text: Text to display (usually first letter of name)
    ///   - backgroundColor: Background color
    ///   - size: Size of the avatar
    /// - Returns: Generated avatar image
    static func generatePlaceholderAvatar(text: String, backgroundColor: UIColor = .systemBlue, size: CGFloat = 100) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))

        return renderer.image { context in
            // Draw background circle
            backgroundColor.setFill()
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            context.cgContext.fillEllipse(in: rect)

            // Draw text
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let fontSize = size * 0.5
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]

            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(
                x: 0,
                y: (size - textSize.height) / 2,
                width: size,
                height: textSize.height
            )

            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }
}
