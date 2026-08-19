//
//  BlurHashFidelityTests.swift
//  Construct MessengerTests
//
//  Does the placeholder look like the picture it stands for?
//

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Construct_Messenger

#if canImport(UIKit)
final class BlurHashFidelityTests: XCTestCase {

    /// A flat colour has no detail to lose, so the round trip is exact up to quantisation.
    /// Anything else means the transform itself is wrong, not that the preview is blurry.
    private func assertRoundTrip(
        _ colour: UIColor,
        tolerance: CGFloat = 0.06,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let source = Self.solidImage(colour, size: CGSize(width: 64, height: 64))
        guard let hash = BlurHash.encode(source) else {
            return XCTFail("encode returned nil", file: file, line: line)
        }
        guard let decoded = BlurHash.decode(hash, size: CGSize(width: 8, height: 8)) else {
            return XCTFail("decode returned nil", file: file, line: line)
        }

        let (sr, sg, sb) = Self.components(of: colour)
        let (dr, dg, db) = Self.averageRGB(of: decoded)

        XCTAssertEqual(dr, sr, accuracy: tolerance, "red drifted", file: file, line: line)
        XCTAssertEqual(dg, sg, accuracy: tolerance, "green drifted", file: file, line: line)
        XCTAssertEqual(db, sb, accuracy: tolerance, "blue drifted", file: file, line: line)
    }

    func testMidGreySurvivesTheRoundTrip() {
        assertRoundTrip(UIColor(white: 0.5, alpha: 1))
    }

    /// The reported symptom is "dirty dark colours, contrast maxed". Mid-tones are where
    /// that shows: a transform that darkens leaves black and white alone and crushes
    /// everything between them.
    func testMidTonesAreNotDarkened() {
        assertRoundTrip(UIColor(red: 0.55, green: 0.42, blue: 0.30, alpha: 1))
        assertRoundTrip(UIColor(red: 0.30, green: 0.55, blue: 0.70, alpha: 1))
    }

    func testSaturatedColoursKeepTheirHue() {
        assertRoundTrip(UIColor(red: 0.80, green: 0.20, blue: 0.20, alpha: 1))
    }

    func testBlackAndWhiteAreNotClipped() {
        assertRoundTrip(.black)
        assertRoundTrip(.white)
    }

    /// A source with an alpha channel — the sticker case, and the suspected cause of the
    /// "dirty dark" preview. `downscaledRGBA` draws into a zero-filled premultiplied buffer,
    /// i.e. transparent black, then reads the bytes back as though they were straight sRGB.
    /// If that is what happens, a 50%-opaque white encodes as mid grey rather than white.
    func testTranslucentSourceIsNotDarkenedByTheBackingBuffer() {
        let half = Self.solidImage(UIColor(white: 1.0, alpha: 0.5),
                                   size: CGSize(width: 64, height: 64),
                                   opaque: false)
        guard let hash = BlurHash.encode(half),
              let decoded = BlurHash.decode(hash, size: CGSize(width: 8, height: 8)) else {
            return XCTFail("round trip failed")
        }
        let (r, g, b) = Self.averageRGB(of: decoded)
        XCTAssertGreaterThan(r, 0.85, "translucent white darkened to \(r)")
        XCTAssertGreaterThan(g, 0.85, "translucent white darkened to \(g)")
        XCTAssertGreaterThan(b, 0.85, "translucent white darkened to \(b)")
    }

    /// Detail, not a flat fill. A blurred preview of a light scene must stay light: the
    /// mean of the placeholder should track the mean of the source, or the preview reads
    /// as a different picture than the one arriving.
    func testABrightGradientStaysBright() {
        let source = Self.horizontalGradient(
            from: UIColor(white: 0.62, alpha: 1),
            to: UIColor(white: 0.94, alpha: 1),
            size: CGSize(width: 64, height: 64)
        )
        let sourceMean = Self.averageRGB(of: source)
        guard let hash = BlurHash.encode(source),
              let decoded = BlurHash.decode(hash, size: CGSize(width: 16, height: 16)) else {
            return XCTFail("round trip failed")
        }
        let decodedMean = Self.averageRGB(of: decoded)
        XCTAssertEqual(decodedMean.0, sourceMean.0, accuracy: 0.06,
                       "gradient mean drifted \(sourceMean.0) → \(decodedMean.0)")
    }

    // MARK: - Helpers

    private static func horizontalGradient(from: UIColor, to: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(
                colorsSpace: space,
                colors: [from.cgColor, to.cgColor] as CFArray,
                locations: [0, 1]
            )!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: 0),
                options: []
            )
        }
    }

    private static func solidImage(_ colour: UIColor, size: CGSize, opaque: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            colour.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func components(of colour: UIColor) -> (CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    /// Mean channel value of the decoded placeholder, in 0...1 sRGB.
    private static func averageRGB(of image: UIImage) -> (CGFloat, CGFloat, CGFloat) {
        guard let cg = image.cgImage else { return (-1, -1, -1) }
        let w = cg.width, h = cg.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (-1, -1, -1) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r = 0, g = 0, b = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = 4 * x + y * bytesPerRow
                r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
            }
        }
        let n = CGFloat(w * h) * 255
        return (CGFloat(r) / n, CGFloat(g) / n, CGFloat(b) / n)
    }
}
#endif
