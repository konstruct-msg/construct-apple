//
//  CallVideo.swift
//  Construct Messenger
//
//  The decisions of a video call that do not need a camera or a peer connection to be made, so a
//  test can reach them. `client/specs/VIDEO_CALLS_DESIGN.md` in the vault; stage 1 of TODO 105.
//
//  Every call carries a video transceiver (owner, 2026-10-03), so turning the camera on is a track
//  swap on a sender that already exists — no renegotiation, no crossing offers. What the swap does
//  not tell the peer is *why* frames stopped: a removed track and a stalled network look the same
//  to the receiver, which keeps showing the last frame. `MediaUpdate` says it, inside the ratchet,
//  so the peer shows the avatar instead of a frozen face.
//

import Foundation

enum CallVideoSide {
    case local
    case remote
}

enum CameraFacing: Equatable {
    case front
    case back

    var flipped: CameraFacing { self == .front ? .back : .front }
}

/// What each side of the call shows, as far as the camera goes.
struct CallVideoState: Equatable {
    /// This side has a video sender — false when the offer came from a client that offers audio
    /// only, and then there is nothing to turn on.
    var canSend = false
    /// What the person asked for with the camera button.
    var localCameraOn = false
    /// What the peer last said about its camera. Starts off: a peer that never says anything (an
    /// older client) is shown as its avatar, which is what it is sending.
    var remoteCameraOn = false
    var facing: CameraFacing = .front
    /// iOS takes the camera from an app in the background, so frames stop although the person
    /// did not turn the camera off.
    var isInBackground = false

    /// What the peer is told. The camera the person turned on but the system took away counts as
    /// off — otherwise the peer watches a frozen frame for as long as we are in the background.
    var announcedCameraOn: Bool { canSend && localCameraOn && !isInBackground }

    /// Apply a change to our side, with `canSend` as the session now has it, and return what the
    /// peer must be told — the new announced state — or nil when that did not change.
    ///
    /// "Before" is read here, before the change, and nowhere else. Until 2026-10-05 the button
    /// changed the state first and a helper read "before" afterwards, so the two always matched:
    /// a callee who turned the camera on was never announced, and the caller saw their avatar
    /// while they saw themselves (two devices, build 716).
    mutating func apply(_ change: (inout CallVideoState) -> Void, canSend: Bool?) -> Bool? {
        let before = announcedCameraOn
        change(&self)
        if let canSend { self.canSend = canSend }
        return announcedCameraOn == before ? nil : announcedCameraOn
    }
}

/// The camera half of `MediaUpdate`. The proto has room for audio and screen too; neither is sent
/// by this app, and the reader ignores them rather than guessing what they would mean.
enum CallVideoSignal {
    static func mediaUpdate(cameraOn: Bool, atMs: Int64) -> Shared_Proto_Signaling_V1_MediaUpdate {
        var update = Shared_Proto_Signaling_V1_MediaUpdate()
        update.updateType = .mute
        update.mediaType = .video
        update.enabled = cameraOn
        update.updatedAt = atMs
        return update
    }

    /// Whether the peer's camera is on after this update, or nil when it is not about the camera.
    static func remoteCameraOn(after update: Shared_Proto_Signaling_V1_MediaUpdate) -> Bool? {
        guard update.mediaType == .video else { return nil }
        switch update.updateType {
        case .mute: return update.enabled
        case .add: return true
        case .remove: return false
        default: return nil
        }
    }
}

/// Which capture format to ask the camera for.
enum CallVideoCapture {
    /// 720p: enough for a phone screen, and what the design budgets the uplink for. WebRTC scales
    /// down from here on a poor network (`degradationPreference = balanced`), never up.
    static let maxWidth: Int32 = 1280
    static let maxHeight: Int32 = 720
    static let maxFps = 30

    /// One capture format as the camera reports it. Dimensions are the sensor's, landscape.
    struct Candidate: Equatable {
        let width: Int32
        let height: Int32
        /// The frame-rate ranges the format supports, as AVFoundation lists them.
        let rateRanges: [ClosedRange<Double>]
        /// The pixel format WebRTC's capturer prefers, so it need not convert every frame.
        let isPreferredPixelFormat: Bool

        var area: Int { Int(width) * Int(height) }
        /// The rate we would ask of this format: 30, or its own maximum if lower.
        var fps: Int { max(1, min(CallVideoCapture.maxFps, Int(maxFps))) }
        var maxFps: Double { rateRanges.map(\.upperBound).max() ?? 0 }
        /// Whether it can run at that rate. A slow-motion format's range can start above 30, and
        /// asking it for 30 raises inside AVFoundation, on WebRTC's capture queue, where nothing
        /// catches it — the flip-to-back-camera crash of build 716 (2026-10-05).
        var canRun: Bool { rateRanges.contains { $0.contains(Double(fps)) } }
    }

    /// The format to capture with and the rate to ask of it: the largest that fits 1280×720 and can
    /// run at our rate; the smallest usable one if nothing fits. Of equals, the preferred pixel
    /// format, then the lowest maximum rate — the ordinary format over its slow-motion twins.
    ///
    /// Until 2026-10-05 this compared area alone, and of several 1280×720 formats `max(by:)` took
    /// the last: on a back camera, a high-speed one.
    static func choose(_ candidates: [Candidate]) -> (index: Int, fps: Int)? {
        let usable = candidates.indices.filter { candidates[$0].canRun }
        let fitting = usable.filter { candidates[$0].width <= maxWidth && candidates[$0].height <= maxHeight }
        let better: (Int, Int) -> Bool = { a, b in
            let x = candidates[a], y = candidates[b]
            if x.area != y.area { return x.area > y.area }
            if x.isPreferredPixelFormat != y.isPreferredPixelFormat { return x.isPreferredPixelFormat }
            return x.maxFps < y.maxFps
        }
        let pick = fitting.min(by: better)
            ?? usable.min { candidates[$0].area < candidates[$1].area }
        return pick.map { ($0, candidates[$0].fps) }
    }
}
