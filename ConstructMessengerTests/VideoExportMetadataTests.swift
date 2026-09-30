//
//  VideoExportMetadataTests.swift
//  ConstructMessengerTests
//
//  A sent video carries the picture and nothing about where or when it was shot. The source
//  here is written with a location and a capture date, as a camera writes them; the exported
//  file must hold neither, at every quality — passthrough included — and keep the orientation,
//  which is the track's transform rather than metadata.
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
            let track = try await XCTUnwrapAsync(await exported.loadTracks(withMediaType: .video).first)
            let transform = try await track.load(.preferredTransform)
            XCTAssertEqual(transform, Self.rotation, "\(quality): the orientation must survive")
        }
    }

    private static let captured = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00+04:00")

    private static let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)

    private func XCTUnwrapAsync<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

    /// A 0.5 s, 64×64 H.264 file, turned a quarter, with a location and a creation date.
    private static func writeSourceVideo() async throws -> URL {
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
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        input.transform = rotation
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }
}
