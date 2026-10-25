//
//  StudioScreen.swift
//  Construct Messenger
//
//  The host's DAW windows as a second video track of the call (`decisions/studio-mode-on-desktop.md`,
//  step 5), the parts with no WebRTC in them: what size the capture is, how the track is found in
//  an offer, and how the guest holds a frame back until the program it belongs to is heard.
//

import Foundation

enum StudioScreen {
    /// The media stream id of the screen track — what tells it apart from the camera's ("video")
    /// in an offer.
    static let streamId = "studio-screen"
    static let trackId = "studio-screen0"

    /// About 1440p: a DAW's text and meters are read, so resolution goes before frame rate.
    static let maxWidth = 2_560
    static let maxHeight = 1_440
    static let maxFps = 30
    /// The track's ceiling. The program is never cut for it: it rides its own channel, and the
    /// encoder gives up frames first (`maintainResolution`).
    static let maxBitrateBps = 6_000_000

    /// `width`×`height` scaled down, aspect kept, to fit `maxWidth`×`maxHeight`; never scaled up.
    /// Even sides: the encoder's 4:2:0 frames have no odd ones.
    static func fit(width: Int, height: Int, maxWidth: Int = maxWidth, maxHeight: Int = maxHeight) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = min(1, Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        func even(_ side: Double) -> Int { max(2, Int(side.rounded(.down)) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }
}

extension StudioOffer {
    /// The `mid` of the offer's screen section — the video section whose `msid` names
    /// `StudioScreen.streamId` — or nil when the offer has none. By line, like `carriesStudio`.
    static func screenMid(sdp: String) -> String? {
        var inVideo = false
        var mid: String?
        var isScreen = false
        for line in sdp.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("m=") {
                if inVideo, isScreen, let mid { return mid }
                inVideo = line.hasPrefix("m=video")
                mid = nil
                isScreen = false
            } else if inVideo, line.hasPrefix("a=mid:") {
                mid = String(line.dropFirst("a=mid:".count))
            } else if inVideo, line.hasPrefix("a=msid:\(StudioScreen.streamId) ") {
                isScreen = true
            }
        }
        return inVideo && isScreen ? mid : nil
    }
}

/// The guest's screen frames, each held until `delay` after it arrived, so the picture is seen
/// when the program it shows is heard: the program waits in its buffer for that long, the frames
/// do not. A frame overtaken by a later one that is also due is dropped — showing a stale frame
/// late would put the cursor behind the sound.
struct StudioScreenDelay<Frame> {
    let delay: Double
    /// Frames held at most; past it the oldest go. A second at the top frame rate is more than any
    /// buffer the invite asks for.
    let capacity: Int
    private var held: [(frame: Frame, arrivedAt: Double)] = []

    init(delay: Double, capacity: Int = StudioScreen.maxFps * 2) {
        self.delay = delay
        self.capacity = max(1, capacity)
    }

    var count: Int { held.count }

    mutating func arrive(_ frame: Frame, at time: Double) {
        if held.count == capacity { held.removeFirst() }
        held.append((frame, time))
    }

    /// The newest frame due by `now`, taken off with every frame before it; nil when none is due.
    mutating func due(at now: Double) -> Frame? {
        guard let last = held.lastIndex(where: { $0.arrivedAt + delay <= now }) else { return nil }
        let frame = held[last].frame
        held.removeFirst(last + 1)
        return frame
    }
}
