//
//  ImageHelper.swift
//  Construct Messenger
//

#if canImport(UIKit)
import UIKit

struct ImageHelper {
    // MARK: - Avatar Processing

    static let maxAvatarSize: CGFloat = 1024
    static let avatarCompressionQuality: CGFloat = 0.7
    static let maxAvatarFileSize: Int = 40 * 1024

    static func prepareAvatarImage(_ image: UIImage) -> Data? {
        guard let resizedImage = resizeAndCropToSquare(image, size: maxAvatarSize) else { return nil }
        guard var imageData = resizedImage.jpegData(compressionQuality: avatarCompressionQuality) else { return nil }
        var quality = avatarCompressionQuality
        while imageData.count > maxAvatarFileSize && quality > 0.1 {
            quality -= 0.1
            if let compressedData = resizedImage.jpegData(compressionQuality: quality) { imageData = compressedData } else { break }
        }
        guard imageData.count <= maxAvatarFileSize else { return nil }
        return imageData
    }

    static func imageFromData(_ data: Data?) -> UIImage? {
        guard let data = data else { return nil }
        return UIImage(data: data)
    }

    private static func resizeAndCropToSquare(_ image: UIImage, size: CGFloat) -> UIImage? {
        let originalSize = image.size
        let scale = max(size / originalSize.width, size / originalSize.height)
        let scaledWidth = originalSize.width * scale
        let scaledHeight = originalSize.height * scale
        let cropX = (scaledWidth - size) / 2
        let cropY = (scaledHeight - size) / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: size, height: size)))
            image.draw(in: CGRect(x: -cropX, y: -cropY, width: scaledWidth, height: scaledHeight))
        }
    }

    static func generatePlaceholderAvatar(text: String, backgroundColor: UIColor = .systemBlue, size: CGFloat = 100) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            backgroundColor.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let fontSize = size * 0.5
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let textRect = CGRect(x: 0, y: (size - textSize.height) / 2, width: size, height: textSize.height)
            (text as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }
}

#else
import AppKit

struct ImageHelper {
    static let maxAvatarSize: CGFloat = 1024
    static let avatarCompressionQuality: CGFloat = 0.7
    static let maxAvatarFileSize: Int = 40 * 1024

    static func prepareAvatarImage(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: avatarCompressionQuality])
    }

    static func imageFromData(_ data: Data?) -> NSImage? {
        guard let data = data else { return nil }
        return NSImage(data: data)
    }

    static func generatePlaceholderAvatar(text: String, backgroundColor: NSColor = .systemBlue, size: CGFloat = 100) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        backgroundColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let fontSize = size * 0.5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = NSRect(x: 0, y: (size - textSize.height) / 2, width: size, height: textSize.height)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
        image.unlockFocus()
        return image
    }
}
#endif
