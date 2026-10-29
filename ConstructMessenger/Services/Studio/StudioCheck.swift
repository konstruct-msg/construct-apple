//
//  StudioCheck.swift
//  Construct Messenger
//
//  Studio's check before a call (owner, 2026-10-28: "as in Zoom, start Studio before the call to
//  see whether the sound goes"): the DAW's sound, its windows, the talkback microphone and the
//  permissions behind them, on this Mac, with nothing sent anywhere. This file is what the check
//  decides — the level of the program and what is wrong; Desktop captures and shows.
//

import Foundation

/// The program's level from the packets the capture makes: peak per channel since the last read,
/// clipping held until reset, and how long the program has been silent.
struct StudioMeter: Equatable, Sendable {
    /// The packetizer's sample scale: 24-bit, clipped at full scale.
    static let fullScale: Int32 = (1 << 23) - 1
    /// The meter's floor; quieter reads as this.
    static let floorDB: Float = -60
    /// Full-scale samples in a row that count as clipping, not one loud peak at 0 dBFS.
    static let clipRun = 3

    private(set) var peakLeft: Int32 = 0
    private(set) var peakRight: Int32 = 0
    private(set) var clipped = false
    /// Frames since the last non-zero sample; the program is silent when this grows.
    private(set) var silentFrames = 0
    /// True once any non-zero sample arrived.
    private(set) var heardAnything = false
    private var fullScaleRun = 0

    /// One packet, interleaved stereo.
    mutating func ingest(_ samples: [Int32]) {
        for (i, sample) in samples.enumerated() {
            let magnitude = sample == Int32.min ? Int32.max : abs(sample)
            if i % 2 == 0 { peakLeft = max(peakLeft, magnitude) } else { peakRight = max(peakRight, magnitude) }
            if magnitude >= Self.fullScale {
                fullScaleRun += 1
                if fullScaleRun >= Self.clipRun { clipped = true }
            } else {
                fullScaleRun = 0
            }
            if i % 2 == 1 {
                if sample != 0 || samples[i - 1] != 0 {
                    silentFrames = 0
                    heardAnything = true
                } else {
                    silentFrames += 1
                }
            }
        }
    }

    /// The peaks since the last read, in dBFS, and the meter starts over for the next.
    mutating func takePeaks() -> (left: Float, right: Float) {
        defer { peakLeft = 0; peakRight = 0 }
        return (Self.dBFS(peakLeft), Self.dBFS(peakRight))
    }

    mutating func resetClip() { clipped = false }

    static func dBFS(_ peak: Int32) -> Float {
        guard peak > 0 else { return floorDB }
        return max(floorDB, 20 * log10(Float(peak) / Float(fullScale)))
    }

    /// The meter's fill, 0…1, from a level in dBFS.
    static func fill(_ dB: Float) -> Double {
        Double((max(floorDB, min(0, dB)) - floorDB) / -floorDB)
    }
}

/// What the check found wrong, in the order it is shown; the window says each in words with
/// what to do about it.
enum StudioCheckFinding: Equatable, Sendable {
    /// No DAW to take the sound from: none chosen and none known running.
    case noSource
    /// The DAW runs and has not played anything since it opened, so the system has nothing to
    /// tap yet.
    case sourceNeverPlayed
    /// The output device runs at another rate; Studio sends 48 kHz only.
    case sampleRate(Int)
    /// The tap could not be made for another reason (in the log).
    case captureFailed
    /// The tap runs and has delivered only silence for a while: nothing plays, or the system's
    /// audio-capture permission was refused — a refused tap gives silence, not an error.
    case silent
    /// The program reaches full scale: it will clip on the other side too.
    case clipping
    case screenPermissionMissing
    /// The DAW has no window on screen to show.
    case screenNoWindow
    case microphonePermissionMissing
}

/// How the program capture ended up, as the check knows it.
enum StudioCheckCapture: Equatable, Sendable {
    case notStarted
    case failed(StudioCheckFinding)
    case running(StudioMeter)
}

enum StudioCheckScreen: Equatable, Sendable {
    case notStarted
    case permissionMissing
    case noWindow
    case failed
    case showing
}

enum StudioCheck {
    /// Silence this long, with the tap running, is said: a second and a half.
    static let silentAfterFrames = 72_000

    static func findings(source: StudioSource?, capture: StudioCheckCapture, screen: StudioCheckScreen,
                         sendsScreen: Bool, microphoneAllowed: Bool) -> [StudioCheckFinding] {
        var found: [StudioCheckFinding] = []
        if source == nil {
            found.append(.noSource)
        } else {
            switch capture {
            case .notStarted:
                break
            case .failed(let finding):
                found.append(finding)
            case .running(let meter):
                if meter.silentFrames >= silentAfterFrames { found.append(.silent) }
                if meter.clipped { found.append(.clipping) }
            }
            if sendsScreen {
                switch screen {
                case .permissionMissing: found.append(.screenPermissionMissing)
                case .noWindow: found.append(.screenNoWindow)
                case .notStarted, .failed, .showing: break
                }
            }
        }
        if !microphoneAllowed { found.append(.microphonePermissionMissing) }
        return found
    }
}
