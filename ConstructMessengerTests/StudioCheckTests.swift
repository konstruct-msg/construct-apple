//
//  StudioCheckTests.swift
//  ConstructMessengerTests
//

import Synchronization
import XCTest
@testable import Construct_Messenger

final class StudioCheckTests: XCTestCase {

    private let full = StudioMeter.fullScale
    private let daw = StudioSource(bundleID: "com.cockos.reaper", name: "REAPER")

    /// Interleaved stereo: `frames` frames of `left`, `right`.
    private func packet(_ left: Int32, _ right: Int32, frames: Int = 1024) -> [Int32] {
        Array((0..<frames).flatMap { _ in [left, right] })
    }

    func testMeter_PeaksPerChannel_InDBFS_ThenStartOver() {
        var meter = StudioMeter()
        meter.ingest(packet(full / 2, full / 10))
        let peaks = meter.takePeaks()
        XCTAssertEqual(peaks.left, -6.02, accuracy: 0.05)
        XCTAssertEqual(peaks.right, -20, accuracy: 0.05)
        XCTAssertEqual(meter.takePeaks().left, StudioMeter.floorDB, "read once")
    }

    func testMeter_NegativeSamplesCount() {
        var meter = StudioMeter()
        meter.ingest(packet(-full / 2, 0))
        XCTAssertEqual(meter.takePeaks().left, -6.02, accuracy: 0.05)
    }

    /// One sample at full scale is a peak; a run of them is clipping, held until reset.
    func testMeter_ClippingIsARun_HeldUntilReset() {
        var meter = StudioMeter()
        meter.ingest([full, 0, 0, 0, 0, 0])
        XCTAssertFalse(meter.clipped)
        meter.ingest(packet(full, full, frames: 2))
        XCTAssertTrue(meter.clipped)
        meter.ingest(packet(0, 0))
        XCTAssertTrue(meter.clipped, "held")
        meter.resetClip()
        XCTAssertFalse(meter.clipped)
    }

    /// Silence counts frames from the last sound; any sound starts it over.
    func testMeter_SilenceCountsFramesSinceSound() {
        var meter = StudioMeter()
        meter.ingest(packet(0, 0, frames: 100))
        XCTAssertEqual(meter.silentFrames, 100)
        XCTAssertFalse(meter.heardAnything)
        meter.ingest(packet(0, 5, frames: 1) + packet(0, 0, frames: 10))
        XCTAssertEqual(meter.silentFrames, 10)
        XCTAssertTrue(meter.heardAnything)
    }

    func testFill_FloorToFullScale() {
        XCTAssertEqual(StudioMeter.fill(StudioMeter.floorDB), 0)
        XCTAssertEqual(StudioMeter.fill(0), 1)
        XCTAssertEqual(StudioMeter.fill(-30), 0.5, accuracy: 0.001)
        XCTAssertEqual(StudioMeter.fill(-90), 0)
    }

    func testFindings_AllWellIsEmpty() {
        var meter = StudioMeter()
        meter.ingest(packet(full / 4, full / 4))
        XCTAssertEqual(StudioCheck.findings(source: daw, capture: .running(meter), screen: .showing,
                                            sendsScreen: true, microphoneAllowed: true), [])
    }

    func testFindings_NoSource_SaysOnlyThatAndTheMicrophone() {
        XCTAssertEqual(StudioCheck.findings(source: nil, capture: .failed(.captureFailed), screen: .noWindow,
                                            sendsScreen: true, microphoneAllowed: false),
                       [.noSource, .microphonePermissionMissing])
    }

    /// Silence is said only once it has lasted; clipping as soon as it happened.
    func testFindings_SilenceAfterAWhile_Clipping() {
        var meter = StudioMeter()
        meter.ingest(packet(0, 0, frames: StudioCheck.silentAfterFrames - 1))
        XCTAssertEqual(StudioCheck.findings(source: daw, capture: .running(meter), screen: .showing,
                                            sendsScreen: true, microphoneAllowed: true), [])
        meter.ingest(packet(full, full, frames: 3) + packet(0, 0, frames: StudioCheck.silentAfterFrames))
        XCTAssertEqual(StudioCheck.findings(source: daw, capture: .running(meter), screen: .showing,
                                            sendsScreen: true, microphoneAllowed: true), [.silent, .clipping])
    }

    func testFindings_CaptureFailureIsSaid() {
        XCTAssertEqual(StudioCheck.findings(source: daw, capture: .failed(.sampleRate(44_100)), screen: .showing,
                                            sendsScreen: true, microphoneAllowed: true), [.sampleRate(44_100)])
    }

    /// The screen's problems count only when the screen is to be sent.
    func testFindings_ScreenOnlyWhenSent() {
        XCTAssertEqual(StudioCheck.findings(source: daw, capture: .notStarted, screen: .permissionMissing,
                                            sendsScreen: true, microphoneAllowed: true), [.screenPermissionMissing])
        XCTAssertEqual(StudioCheck.findings(source: daw, capture: .notStarted, screen: .noWindow,
                                            sendsScreen: true, microphoneAllowed: true), [.screenNoWindow])
        XCTAssertEqual(StudioCheck.findings(source: daw, capture: .notStarted, screen: .permissionMissing,
                                            sendsScreen: false, microphoneAllowed: true), [])
    }

    /// The packetizer's callback runs on the capture's thread: Core Audio's I/O thread, never the
    /// main actor. A callback made in a main-actor method, with a lock taken inside it as the
    /// check's meter does, was isolated to the main actor, and Swift 6 trapped on the first packet
    /// (Desktop 0.3.17, 2026-10-28: the check crashed as soon as Reaper played).
    ///
    /// Mutation: drop `@Sendable` from `onPacket` — this test traps.
    @MainActor
    func testPacketizerCallbackRunsOffTheMainActor() async {
        let delivered = expectation(description: "packet")
        let owner = MainActorPacketizerOwner(delivered: delivered)
        nonisolated(unsafe) let fed: StudioCapturePacketizer = owner.packetizer
        let frames = Int(StudioAudioFormat.lossless.framesPerPacket)
        DispatchQueue(label: "studio.test.tap").async {
            let samples = [Float](repeating: 0.25, count: frames * 2)
            samples.withUnsafeBufferPointer { fed.ingest(interleaved: $0, channels: 2) }
        }
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(owner.meter.value.withLock { $0.heardAnything }, true)
    }
}

/// Builds a packetizer the way `StudioCheckModel` does: in a main-actor method, into a meter
/// behind a lock.
@MainActor
private final class MainActorPacketizerOwner {
    final class Box: Sendable { let value = Mutex(StudioMeter()) }
    let meter = Box()
    var packetizer: StudioCapturePacketizer!

    init(delivered: XCTestExpectation) {
        let box = meter
        nonisolated(unsafe) let delivered = delivered
        packetizer = StudioCapturePacketizer(format: .lossless) { samples, _ in
            box.value.withLock { $0.ingest(samples) }
            delivered.fulfill()
        }
    }
}
