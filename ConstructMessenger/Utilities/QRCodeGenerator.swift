//
//  QRCodeGenerator.swift
//  Construct Messenger
//
//  Shared QR code generation with Konstruct logo overlay.
//  Uses error correction level H (30% recovery) so the logo can safely
//  cover ~20% of the code area without making it unreadable.
//

import CoreImage.CIFilterBuiltins
import CoreGraphics

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum QRCodeGenerator {
    /// Scale factor applied to the raw 1-pt-per-module CIFilter output.
    /// 12× gives a crisp image at any size up to ~360 pt (standard display).
    private static let scale: CGFloat = 12

    /// Logo covers this fraction of the QR image's shorter dimension.
    private static let logoFraction: CGFloat = 0.22

    /// Opaque padding added on each side of the logo (as a fraction of logoEdge).
    /// 0.05 = 5% per side = 10% total. The white patch is then snapped outward to
    /// the nearest QR module boundary so no module is sliced in half.
    private static let logoPaddingFraction: CGFloat = 0.05

    // MARK: - Public API

    #if canImport(UIKit)
    static func generate(from string: String) -> UIImage? {
        guard let qr = generateBase(from: string) else { return nil }
        return UIImage(cgImage: composited(qr))
    }
    #else
    static func generate(from string: String) -> NSImage? {
        guard let qr = generateBase(from: string) else { return nil }
        let composited = composited(qr)
        return NSImage(cgImage: composited, size: NSSize(width: composited.width, height: composited.height))
    }
    #endif

    // MARK: - Private

    private static func generateBase(from string: String) -> CGImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // H = 30% error recovery — required to survive the logo occlusion.
        filter.correctionLevel = "H"
        guard let raw = filter.outputImage else { return nil }
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }

    private static func composited(_ qr: CGImage) -> CGImage {
        let size = CGSize(width: qr.width, height: qr.height)
        guard let ctx = CGContext(
            data: nil,
            width: qr.width,
            height: qr.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return qr }

        // Draw QR code
        ctx.draw(qr, in: CGRect(origin: .zero, size: size))

        // Load logo — force light trait so we always get the dark-on-transparent variant
        // (QR background is white; the dark logo provides maximum contrast).
        let logo: CGImage? = {
            #if canImport(UIKit)
            let traits = UITraitCollection(userInterfaceStyle: .light)
            return UIImage(named: "KonstructLogo", in: nil, compatibleWith: traits)?.cgImage
            #else
            return NSImage(named: "KonstructLogo").flatMap { img in
                var rect = NSRect(origin: .zero, size: img.size)
                return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            }
            #endif
        }()

        guard let logo else { return qr }

        let logoEdge = size.width * logoFraction
        let padding  = logoEdge * logoPaddingFraction
        let bgEdgeRaw = logoEdge + padding * 2

        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // Snap the white background patch to the QR module grid.
        // Each QR module is exactly `scale` pixels wide/tall after the CIFilter scale step.
        // Expanding to the nearest outer module boundary ensures no module is half-covered.
        let mod = scale
        let rawBgX   = center.x - bgEdgeRaw / 2
        let rawBgY   = center.y - bgEdgeRaw / 2
        let snappedX    = floor(rawBgX    / mod) * mod
        let snappedY    = floor(rawBgY    / mod) * mod
        let snappedMaxX = ceil((rawBgX + bgEdgeRaw) / mod) * mod
        let snappedMaxY = ceil((rawBgY + bgEdgeRaw) / mod) * mod
        let bgRect  = CGRect(x: snappedX, y: snappedY,
                             width: snappedMaxX - snappedX, height: snappedMaxY - snappedY)
        let logoRect = CGRect(x: center.x - logoEdge / 2, y: center.y - logoEdge / 2,
                              width: logoEdge, height: logoEdge)

        // White opaque background patch to mask the underlying QR modules
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(bgRect)

        ctx.draw(logo, in: logoRect)

        return ctx.makeImage() ?? qr
    }
}
