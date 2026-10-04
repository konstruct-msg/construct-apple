//
//  VideoExportMetadataTests.swift
//  ConstructMessengerTests
//
//  A sent video carries the picture and nothing about where or when it was shot. The source
//  here is written with a location and a capture date, as a camera writes them; the exported
//  file must hold neither, at every quality — passthrough included — and keep the orientation,
//  which is the track's transform rather than metadata. Passthrough keeps the transform; the
//  compressed qualities render the picture upright, so what is checked is the picture's shape.
//
//  And since 2026-10-04 the compressed qualities are HEVC, scaled to fit their box, SDR, at most
//  30 frames a second — about half the bytes H.264 took.
//

import XCTest
import AVFoundation
import CoreVideo
@testable import Construct_Messenger

final class VideoExportMetadataTests: XCTestCase {

    func testExportCarriesNoSourceMetadata() async throws {
        let source = try await Self.writeSourceVideo()
        let sourceMetadata = try await AVURLAsset(url: source).load(.metadata)
        XCTAssertFalse(sourceMetadata.isEmpty, "the source must carry metadata, or this proves nothing")

        for quality in VideoQuality.allCases {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-\(quality.rawValue)-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            _ = try await MediaManager.transcodeVideo(
                asset: AVURLAsset(url: source), to: out, quality: quality, onProgress: nil)

            let exported = AVURLAsset(url: out)
            let items = try await exported.load(.metadata)
            XCTAssertTrue(items.isEmpty, "\(quality): \(items.map { $0.identifier?.rawValue ?? "?" })")
            // The container stamps its own creation time — the moment of export, which the send
            // already reveals. What must not survive is the moment of capture.
            let creationDate = try await exported.load(.creationDate)?.load(.dateValue)
            XCTAssertNotEqual(creationDate, Self.captured, "\(quality): the capture date survived")
            let (width, height) = try await Self.uprightSize(of: exported)
            XCTAssertLessThan(width, height, "\(quality): the portrait picture must stay portrait")
        }
    }

    func testCompressedQualitiesAreHEVCInTheirBoxAt30fpsSDR() async throws {
        let source = try await Self.writeSourceVideo(width: 1920, height: 1080, fps: 60)
        for (quality, box) in [(VideoQuality.p720, (1280, 720)), (.p1080, (1920, 1080))] {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("hevc-\(quality.rawValue)-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            _ = try await MediaManager.transcodeVideo(
                asset: AVURLAsset(url: source), to: out, quality: quality, onProgress: nil)

            let track = try await XCTUnwrapAsync(await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
            let (formats, fps) = try await track.load(.formatDescriptions, .nominalFrameRate)
            let format = try XCTUnwrap(formats.first)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC, "\(quality)")
            let primaries = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            XCTAssertEqual(primaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String, "\(quality)")
            XCTAssertLessThanOrEqual(fps, MediaManager.maxSentFrameRate + 0.5, "\(quality)")

            // Source is 1920×1080 turned a quarter: upright it is 1080×1920, fitted to the box.
            let (width, height) = try await Self.uprightSize(of: AVURLAsset(url: out))
            XCTAssertEqual(height, box.0, "\(quality): the long edge fills the box")
            XCTAssertLessThanOrEqual(width, box.1, "\(quality)")
            XCTAssertEqual(width % 2, 0, "\(quality): even dimensions")
        }
    }

    /// The displayed size: the track's natural size through its transform.
    private static func uprightSize(of asset: AVURLAsset) async throws -> (Int, Int) {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = size.applying(transform)
        return (Int(abs(upright.width).rounded()), Int(abs(upright.height).rounded()))
    }

    private static let captured = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00+04:00")

    private static let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)

    private func XCTUnwrapAsync<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

    /// A 0.5 s H.264 file — 64×32 by default, wider than tall — turned a quarter so it displays
    /// portrait, with a location and a creation date.
    private static func writeSourceVideo(width: Int = 64, height: Int = 32, fps: Int32 = 30) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+40.1792+044.4991/" as NSString
        let created = AVMutableMetadataItem()
        created.identifier = .quickTimeMetadataCreationDate
        created.value = "2026-09-30T12:00:00+0400" as NSString
        writer.metadata = [location, created]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        input.transform = rotation
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(fps / 2) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }
}
