//
//  DesktopCallModel.swift
//  Construct Desktop
//
//  One call as the Desktop call surfaces see it: the call bar in the chat column and the call
//  window read the same phase, duration and microphone state, so the two never disagree. It
//  follows `CallManager` and decides nothing about the call itself — `CallPhase` maps its state.
//
//  A call that ended with something to act on (declined, busy, no answer, failed) is kept here
//  after `CallManager` clears it, until the person closes it or calls back.
//

import AVFoundation
import AppKit
import SwiftUI

@MainActor
@Observable
final class DesktopCallModel {
    static let shared = DesktopCallModel()

    private(set) var session: CallSession?
    private(set) var phase: CallPhase?
    private(set) var connectedSince: Date?
    private(set) var muted = false
    private(set) var micAccess: AVAuthorizationStatus = .notDetermined

    private init() {}

    /// Follow the call manager. Called on every change of its state or quality.
    func sync(state: CallState, quality: CallQuality) {
        if case .active = state, connectedSince == nil { connectedSince = Date() }
        let next = CallPhase.of(state, quality: quality, connectedSeconds: connectedSeconds)

        switch (phase, next) {
        case (.over(let outcome)?, nil) where outcome.wantsAttention:
            // CallManager has cleared the ended call; the outcome stays until it is closed.
            return
        case (_, nil):
            reset()
            return
        default:
            break
        }
        if let s = state.session, s.id != session?.id {
            reset()
            session = s
        }
        phase = next
        if next?.isLive == true { micAccess = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    var connectedSeconds: Int? {
        connectedSince.map { Int(Date().timeIntervalSince($0)) }
    }

    func toggleMute() {
        muted.toggle()
        CallManager.shared.setMuted(muted)
    }

    func end() {
        CallManager.shared.endCall()
    }

    var studioAvailable: Bool { StudioFeature.isEnabled }

    /// On from the host's press (or the guest's join) until either side leaves or the call ends.
    var studioOn: Bool { CallManager.shared.studioIsOn }

    func toggleStudio() {
        if studioOn {
            CallManager.shared.stopStudio()
        } else {
            Task { await CallManager.shared.startStudio() }
        }
    }

    /// Close an outcome that is being kept, or the ended call CallManager still shows.
    func dismiss() {
        CallManager.shared.dismissEndedCall()
        reset()
    }

    func callBack() {
        guard let session else { return }
        let peer = session.peerUserId, name = session.peerName
        dismiss()
        Task { await CallManager.shared.startOutgoingCall(to: peer, displayName: name, hasVideo: false) }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    private func reset() {
        session = nil
        phase = nil
        connectedSince = nil
        muted = false
    }
}

private extension CallState {
    var session: CallSession? {
        switch self {
        case .idle: nil
        case .incoming(let s), .dialing(let s), .ringing(let s), .connecting(let s), .active(let s), .ended(let s, _): s
        }
    }
}
