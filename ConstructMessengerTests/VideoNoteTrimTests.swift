//
//  VideoNoteTrimTests.swift
//  ConstructMessengerTests
//
//  The trim handles of a paused video note, and that the send keeps exactly the trimmed stretch.
//

import XCTest
import AVFoundation
@testable import Construct_Messenger

final class VideoNoteTrimTests: XCTestCase {
    private let shortest = ChatUIConstants.VideoNote.trimMinimumDuration

    func testHandlesStayInsideTheRecording() {
        XCTAssertEqual(VideoTrimBar.moved(start: true, to: -3, from: 2...8, duration: 10), 0...8)
        XCTAssertEqual(VideoTrimBar.moved(start: false, to: 14, from: 2...8, duration: 10), 2...10)
    }

    func testHandlesKeepTheShortestNoteBetweenThem() {
        XCTAssertEqual(VideoTrimBar.moved(start: true, to: 7.9, from: 2...8, duration: 10), (8 - shortest)...8)
        XCTAssertEqual(VideoTrimBar.moved(start: false, to: 2.1, from: 2...8, duration: 10), 2...(2 + shortest))
    }

    func testARecordingShorterThanTheShortestCanStillBeKeptWhole() {
        XCTAssertEqual(VideoTrimBar.moved(start: true, to: 0.2, from: 0...0.5, duration: 0.5), 0...0.5)
    }

    /// The send cuts at the trim, to the frame, rather than at the nearest key frame.
    func testSendKeepsTheTrimmedStretch() async throws {
        let source = try await Self.writeClip(seconds: 2)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("trim-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                end: CMTime(seconds: 1.5, preferredTimescale: 600))
        _ = try await MediaManager.transcodeVideo(
            asset: AVURLAsset(url: source), to: out, render: MediaManager.videoNoteRender,
            timeRange: range, onProgress: nil)
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(duration, 1.0, accuracy: 0.05)
    }

    /// A 30 fps H.264 clip of `seconds`, one key frame at the start — so a cut at 0.5 s falls
    /// between key frames, where a passthrough cut could not land.
    private static func writeClip(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 300],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            adaptor.append(try XCTUnwrap(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }
}
