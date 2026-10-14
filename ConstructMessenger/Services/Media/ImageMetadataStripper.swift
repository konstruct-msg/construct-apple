//
//  ImageMetadataStripper.swift
//  Construct Messenger
//
//  An original-quality photo is sent as the library's file, and the library's file carries EXIF:
//  GPS position, capture time, camera and lens. Until 2026-09-30 it went out as it was. This
//  keeps the pixels and the orientation and nothing else.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageMetadataStripper {

    /// `data` with every metadata item removed except the orientation. The compressed image is
    /// copied as it is where that leaves nothing behind (JPEG); otherwise it is decoded and
    /// written again at full quality. Each result is read back and checked against
    /// `carriesNothingButThePicture` — ImageIO's "replace the metadata" is not honoured by every
    /// format (PNG kept all of it, HEIC the capture time). `nil` when no result passes: the
    /// caller must not send the original then.
    static func strip(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[
            kCGImagePropertyOrientation
        ]
        if let copied = copyWithoutMetadata(source, type: type, orientation: orientation),
           carriesNothingButThePicture(copied) {
            return copied
        }
        if let written = reencode(source, type: type, orientation: orientation),
           carriesNothingButThePicture(written) {
            return written
        }
        return nil
    }

    /// Every property ImageIO reads from `data` describes the pixels — size, depth, colour,
    /// orientation, resolution — and nothing else. An allowlist: a key this does not know is
    /// treated as metadata.
    static func carriesNothingButThePicture(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        for (key, value) in properties {
            if let allowed = pictureKeysInside[key] {
                guard let inner = value as? [CFString: Any],
                      inner.keys.allSatisfy(allowed.contains) else { return false }
            } else if !pictureKeys.contains(key) {
                return false
            }
        }
        return true
    }

    private static let pictureKeys: Set<CFString> = [
        kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
        kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyHasAlpha,
        kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight,
        kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed, kCGImagePropertyPrimaryImage,
        kCGImagePropertyFileSize, kCGImagePropertyNamedColorSpace,
        "ImageCount" as CFString, "Images" as CFString, "ThumbnailImages" as CFString,
        "Headroom" as CFString,
    ]

    private static let resolution: Set<CFString> = [
        kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution,
        kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit,
        kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
    ]

    private static let pictureKeysInside: [CFString: Set<CFString>] = [
        kCGImagePropertyTIFFDictionary: resolution,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifColorSpace,
        ],
        kCGImagePropertyJFIFDictionary: [
            kCGImagePropertyJFIFVersion, kCGImagePropertyJFIFXDensity,
            kCGImagePropertyJFIFYDensity, kCGImagePropertyJFIFDensityUnit,
            kCGImagePropertyJFIFIsProgressive,
        ],
        kCGImagePropertyPNGDictionary: [
            kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGGamma, kCGImagePropertyPNGsRGBIntent,
            kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter,
            kCGImagePropertyPNGChromaticities, "ColorType" as CFString, "Width" as CFString,
            "Height" as CFString, "BitDepth" as CFString, "Compression" as CFString,
            "Filter" as CFString,
        ],
        kCGImagePropertyHEICSDictionary: [],
    ]

    private static func copyWithoutMetadata(_ source: CGImageSource, type: CFString, orientation: Any?) -> Data? {
        let metadata = CGImageMetadataCreateMutable()
        if let orientation {
            CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyOrientation, orientation as CFTypeRef
            )
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { return nil }
        return out as Data
    }

    private static func reencode(_ source: CGImageSource, type: CFString, orientation: Any?) -> Data? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
