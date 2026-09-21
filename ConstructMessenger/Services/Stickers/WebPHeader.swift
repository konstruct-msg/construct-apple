//
//  WebPHeader.swift
//  Construct Messenger
//
//  Reads a WebP's dimensions and kind from its container header — no decoder, no image
//  framework. A sticker blob is public bytes fetched from a server the client does not have to
//  trust; the header is checked before the bytes are written to cache or handed to a decoder, so
//  a file that claims to be a 512×512 static sticker and is not never gets that far.
//

import Foundation

/// What a sticker image must be. Fixed by sticker-packs-content-addressed.md.
enum StickerImageRules {
    static let canvas = 512
    /// Refused above this before download when the manifest says so, and again on the bytes.
    static let maxBytes = 100 * 1024
}

struct WebPHeader: Equatable {
    enum Kind: Equatable {
        /// `VP8 ` — lossy, no alpha.
        case lossy
        /// `VP8L` — lossless.
        case lossless
        /// `VP8X` — extended: alpha, ICC, EXIF, or animation, flagged.
        case extended(animated: Bool)
    }

    let kind: Kind
    let width: Int
    let height: Int

    enum ParseError: Error, Equatable {
        case notRIFF
        case notWebP
        case truncated
        case unknownChunk(String)
        case badBitstream
    }

    /// The header only: 30 bytes is enough for every kind.
    static func parse(_ data: Data) throws -> WebPHeader {
        let b = data.startIndex == 0 ? data : Data(data)
        guard b.count >= 12 else { throw ParseError.truncated }
        guard b[0..<4] == Data("RIFF".utf8) else { throw ParseError.notRIFF }
        guard b[8..<12] == Data("WEBP".utf8) else { throw ParseError.notWebP }
        guard b.count >= 30 else { throw ParseError.truncated }
        let fourcc = String(decoding: b[12..<16], as: UTF8.self)
        let p = 20   // first byte of the chunk payload

        switch fourcc {
        case "VP8 ":
            // 3-byte frame tag, then the start code 9D 01 2A, then 14-bit width and height
            // each in a little-endian 16-bit word whose top two bits are scale.
            guard b[p + 3] == 0x9D, b[p + 4] == 0x01, b[p + 5] == 0x2A else {
                throw ParseError.badBitstream
            }
            let w = Int(b[p + 6]) | (Int(b[p + 7] & 0x3F) << 8)
            let h = Int(b[p + 8]) | (Int(b[p + 9] & 0x3F) << 8)
            return WebPHeader(kind: .lossy, width: w, height: h)

        case "VP8L":
            // Signature 2F, then 14 bits width-1, 14 bits height-1, 1 bit alpha, 3 bits version.
            guard b[p] == 0x2F else { throw ParseError.badBitstream }
            let b1 = Int(b[p + 1]), b2 = Int(b[p + 2]), b3 = Int(b[p + 3]), b4 = Int(b[p + 4])
            let w = 1 + (b1 | ((b2 & 0x3F) << 8))
            let h = 1 + ((b2 >> 6) | (b3 << 2) | ((b4 & 0x0F) << 10))
            return WebPHeader(kind: .lossless, width: w, height: h)

        case "VP8X":
            // Flags byte, three reserved, then canvas width-1 and height-1 as 24-bit LE.
            let animated = b[p] & 0x02 != 0
            let w = 1 + (Int(b[p + 4]) | (Int(b[p + 5]) << 8) | (Int(b[p + 6]) << 16))
            let h = 1 + (Int(b[p + 7]) | (Int(b[p + 8]) << 8) | (Int(b[p + 9]) << 16))
            return WebPHeader(kind: .extended(animated: animated), width: w, height: h)

        default:
            throw ParseError.unknownChunk(fourcc)
        }
    }

    /// A static image on the sticker canvas. Animation is a separate decision and is refused.
    var isStickerCanvas: Bool {
        if case .extended(animated: true) = kind { return false }
        return width == StickerImageRules.canvas && height == StickerImageRules.canvas
    }
}
