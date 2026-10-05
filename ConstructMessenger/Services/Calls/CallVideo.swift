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

    /// The largest format within 1280×720, by pixel count; the smallest one if the camera has
    /// nothing that small. Dimensions are the sensor's, landscape.
    static func bestFormatIndex(_ dimensions: [(width: Int32, height: Int32)]) -> Int? {
        guard !dimensions.isEmpty else { return nil }
        let area = { (i: Int) in Int(dimensions[i].width) * Int(dimensions[i].height) }
        let fitting = dimensions.indices.filter {
            dimensions[$0].width <= maxWidth && dimensions[$0].height <= maxHeight
        }
        if let best = fitting.max(by: { area($0) < area($1) }) { return best }
        return dimensions.indices.min(by: { area($0) < area($1) })
    }

    static func fps(maxSupported: Double) -> Int {
        max(1, min(maxFps, Int(maxSupported)))
    }
}
