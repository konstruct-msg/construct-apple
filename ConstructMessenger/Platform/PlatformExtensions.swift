// Platform-independent image helpers.
// Wraps UIImage vs NSImage API differences.

import Foundation

#if canImport(UIKit)
import UIKit

extension UIImage {
    func platformPNGData() -> Data? { pngData() }
    func platformJPEGData(quality: CGFloat) -> Data? { jpegData(compressionQuality: quality) }

    static func platformImage(data: Data) -> UIImage? { UIImage(data: data) }
    static func platformImage(named: String) -> UIImage? { UIImage(named: named) }
}

import SwiftUI

extension Image {
    /// Platform-agnostic initialiser: accepts UIImage on iOS/Catalyst, NSImage on macOS.
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}
#elseif canImport(AppKit)
import AppKit

extension NSImage {
    func platformPNGData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    func platformJPEGData(quality: CGFloat) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func platformImage(data: Data) -> NSImage? { NSImage(data: data) }
    static func platformImage(named: String) -> NSImage? { NSImage(named: named) }
}

import SwiftUI

extension Image {
    /// Platform-agnostic initialiser: accepts UIImage on iOS/Catalyst, NSImage on macOS.
    init(platformImage: PlatformImage) {
#if canImport(UIKit)
        self.init(uiImage: platformImage)
#else
        self.init(nsImage: platformImage)
#endif
    }
}
#endif
