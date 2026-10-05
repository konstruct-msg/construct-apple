//
//  VideoCallStage.swift
//  Construct Messenger
//
//  The decisions of the video call screen, apart from the screen so a test can reach them:
//  what fills the screen, what sits in the small window, which corner that window goes to, and
//  when the controls hide. `client/specs/VIDEO_CALLS_DESIGN.md`, "Принцип интерфейса"; the mock is
//  linked from stage 0 there.
//

import CoreGraphics
import SwiftUI

/// What goes where on the video call screen. nil from `make` means the audio screen.
struct VideoCallStage: Equatable {
    enum Pane: Hashable {
        case remoteVideo
        /// The peer's camera is off: their avatar, as in an audio call.
        case remoteAvatar
        case localVideo
        /// Our camera is off while theirs is on — the window stays, so it is clear why they
        /// cannot see us.
        case localCameraOff
    }

    let big: Pane
    let small: Pane?

    /// Only two faces can trade places.
    var canSwap: Bool { big != small && [big, small].allSatisfy { $0 == .remoteVideo || $0 == .localVideo } }

    static func make(_ video: CallVideoState, isConnecting: Bool, isEnded: Bool, swapped: Bool) -> VideoCallStage? {
        guard !isEnded else { return nil }
        switch (video.remoteCameraOn, video.announcedCameraOn) {
        case (false, false):
            return nil
        case (false, true):
            // Before the answer there is nobody to show yet, so our own camera fills the
            // screen, as FaceTime does while it rings.
            return isConnecting
                ? VideoCallStage(big: .localVideo, small: nil)
                : VideoCallStage(big: .remoteAvatar, small: .localVideo)
        case (true, false):
            return VideoCallStage(big: .remoteVideo, small: .localCameraOff)
        case (true, true):
            return swapped
                ? VideoCallStage(big: .localVideo, small: .remoteVideo)
                : VideoCallStage(big: .remoteVideo, small: .localVideo)
        }
    }

    /// The header and the controls go away after a few seconds without a touch — but only over a
    /// face worth seeing whole, never while the call is still being set up, and never under
    /// VoiceOver, where a control that disappears cannot be found again by touch.
    func controlsAutoHide(isConnecting: Bool, voiceOver: Bool) -> Bool {
        big == .remoteVideo && !isConnecting && !voiceOver
    }

    static let controlsHideAfter: Duration = .seconds(3)
}

/// Where the small window sits. It is dragged anywhere and lands in the nearest corner.
enum PreviewCorner: CaseIterable, Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// The corner whose quarter of the screen the point is in.
    static func nearest(to point: CGPoint, in size: CGSize) -> PreviewCorner {
        let leading = point.x < size.width / 2
        let top = point.y < size.height / 2
        switch (top, leading) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    var isTop: Bool { self == .topLeading || self == .topTrailing }
}

enum CallVideoAudio {
    /// Turning the camera on takes the sound off the earpiece: the phone is now held at arm's
    /// length, and the earpiece cannot be heard from there. A headset or a speaker chosen by
    /// hand is left alone.
    static func movesToSpeaker(wasSending: Bool, isSending: Bool, outputIsEarpiece: Bool) -> Bool {
        !wasSending && isSending && outputIsEarpiece
    }
}
