//
//  BlurHash.swift
//  Construct Messenger
//
//  Vendored BlurHash (Wolt algorithm) — encode a tiny (~20–40 char) blurred-preview
//  string from an image and decode it back to a blurred placeholder. Used to ship a
//  cheap preview inside the E2EE media descriptor so the recipient sees a blurred
//  image immediately, clearing to the full download. No third-party dependency.
//

import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum BlurHash {

    // MARK: - Encode

    /// Encode a BlurHash from `image`. The image is downscaled to ≤32px before the
    /// transform, so this is cheap even for full-resolution photos.
    static func encode(_ image: PlatformImage, components: (Int, Int) = (4, 3)) -> String? {
        let cx = max(1, min(9, components.0))
        let cy = max(1, min(9, components.1))
        guard let (pixels, width, height, bytesPerRow) = downscaledRGBA(image, maxDimension: 32),
              width > 0, height > 0 else { return nil }

        var factors: [[Float]] = []
        factors.reserveCapacity(cx * cy)
        for y in 0..<cy {
            for x in 0..<cx {
                let normalisation: Float = (x == 0 && y == 0) ? 1 : 2
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<height {
                    for i in 0..<width {
                        let basis = normalisation
                            * cos(Float.pi * Float(x) * Float(i) / Float(width))
                            * cos(Float.pi * Float(y) * Float(j) / Float(height))
                        let idx = 4 * i + j * bytesPerRow
                        r += basis * sRGBToLinear(Int(pixels[idx]))
                        g += basis * sRGBToLinear(Int(pixels[idx + 1]))
                        b += basis * sRGBToLinear(Int(pixels[idx + 2]))
                    }
                }
                let scale = 1.0 / Float(width * height)
                factors.append([r * scale, g * scale, b * scale])
            }
        }

        let dc = factors[0]
        let ac = Array(factors.dropFirst())

        var hash = ""
        let sizeFlag = (cx - 1) + (cy - 1) * 9
        hash += encode83(sizeFlag, length: 1)

        let maximumValue: Float
        if !ac.isEmpty {
            let actualMax = ac.map { max(abs($0[0]), abs($0[1]), abs($0[2])) }.max() ?? 0
            let quantisedMax = max(0, min(82, Int(actualMax * 166 - 0.5)))
            maximumValue = (Float(quantisedMax) + 1) / 166
            hash += encode83(quantisedMax, length: 1)
        } else {
            maximumValue = 1
            hash += encode83(0, length: 1)
        }

        hash += encode83(encodeDC(dc), length: 4)
        for f in ac { hash += encode83(encodeAC(f, maximumValue: maximumValue), length: 2) }
        return hash
    }

    // MARK: - Decode

    static func decode(_ hash: String, size: CGSize, punch: Float = 1) -> PlatformImage? {
        let chars = Array(hash)
        guard chars.count >= 6 else { return nil }

        let sizeFlag = decode83(chars[0..<1])
        let cy = sizeFlag / 9 + 1
        let cx = sizeFlag % 9 + 1
        guard chars.count == 4 + 2 * cx * cy else { return nil }

        let quantisedMax = decode83(chars[1..<2])
        let maximumValue = Float(quantisedMax + 1) / 166 * punch

        var colours: [[Float]] = []
        colours.reserveCapacity(cx * cy)
        let count = cx * cy
        for i in 0..<count {
            if i == 0 {
                colours.append(decodeDC(decode83(chars[2..<6])))
            } else {
                let value = decode83(chars[(4 + i * 2)..<(6 + i * 2)])
                colours.append(decodeAC(value, maximumValue: maximumValue))
            }
        }

        let w = max(1, Int(size.width))
        let h = max(1, Int(size.height))
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * h)
        for y in 0..<h {
            for x in 0..<w {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for j in 0..<cy {
                    for i in 0..<cx {
                        let basis = cos(Float.pi * Float(x) * Float(i) / Float(w))
                            * cos(Float.pi * Float(y) * Float(j) / Float(h))
                        let c = colours[i + j * cx]
                        r += c[0] * basis
                        g += c[1] * basis
                        b += c[2] * basis
                    }
                }
                let idx = 4 * x + y * bytesPerRow
                pixels[idx] = UInt8(clamping: linearToSRGB(r))
                pixels[idx + 1] = UInt8(clamping: linearToSRGB(g))
                pixels[idx + 2] = UInt8(clamping: linearToSRGB(b))
                pixels[idx + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return nil }
        return platformImage(from: cg)
    }

    // MARK: - base83

    private static let base83 = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~"
    )

    private static func encode83(_ value: Int, length: Int) -> String {
        var result = ""
        for i in 1...length {
            let digit = (value / pow83(length - i)) % 83
            result.append(base83[digit])
        }
        return result
    }

    private static func decode83(_ chars: ArraySlice<Character>) -> Int {
        var value = 0
        for c in chars {
            if let idx = base83.firstIndex(of: c) { value = value * 83 + idx }
        }
        return value
    }

    private static func pow83(_ n: Int) -> Int {
        var r = 1
        for _ in 0..<n { r *= 83 }
        return r
    }

    // MARK: - DC/AC

    private static func encodeDC(_ c: [Float]) -> Int {
        (linearToSRGB(c[0]) << 16) + (linearToSRGB(c[1]) << 8) + linearToSRGB(c[2])
    }

    private static func decodeDC(_ value: Int) -> [Float] {
        [sRGBToLinear(value >> 16), sRGBToLinear((value >> 8) & 255), sRGBToLinear(value & 255)]
    }

    private static func encodeAC(_ c: [Float], maximumValue: Float) -> Int {
        func quant(_ v: Float) -> Int {
            max(0, min(18, Int(signPow(v / maximumValue, 0.5) * 9 + 9.5)))
        }
        return quant(c[0]) * 19 * 19 + quant(c[1]) * 19 + quant(c[2])
    }

    private static func decodeAC(_ value: Int, maximumValue: Float) -> [Float] {
        let r = value / (19 * 19)
        let g = (value / 19) % 19
        let b = value % 19
        return [
            signPow((Float(r) - 9) / 9, 2) * maximumValue,
            signPow((Float(g) - 9) / 9, 2) * maximumValue,
            signPow((Float(b) - 9) / 9, 2) * maximumValue,
        ]
    }

    // MARK: - Colour space

    private static func sRGBToLinear(_ value: Int) -> Float {
        let v = Float(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSRGB(_ value: Float) -> Int {
        let v = max(0, min(1, value))
        return v <= 0.0031308
            ? Int(v * 12.92 * 255 + 0.5)
            : Int((1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    private static func signPow(_ value: Float, _ exp: Float) -> Float {
        copysign(pow(abs(value), exp), value)
    }

    // MARK: - Image helpers

    /// Render `image` into a small RGBA8 bitmap (longest side ≤ maxDimension).
    private static func downscaledRGBA(_ image: PlatformImage, maxDimension: Int)
        -> (pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int)? {
        guard let cg = cgImage(from: image) else { return nil }
        let srcW = cg.width, srcH = cg.height
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1.0, Float(maxDimension) / Float(max(srcW, srcH)))
        let w = max(1, Int(Float(srcW) * scale))
        let h = max(1, Int(Float(srcH) * scale))
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h, bytesPerRow)
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }

    private static func platformImage(from cg: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }
}
