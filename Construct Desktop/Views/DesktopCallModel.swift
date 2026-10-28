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
    /// Talkback while Studio is on: hold to talk or always on. The mode outlives the call.
    private(set) var talkback = StudioTalkback(mode: .stored())
    /// The applications running now that Studio can take its sound and windows from.
    private(set) var studioSources: [StudioSource] = []
    /// The one it takes: chosen before, else a known DAW. Nil when neither runs.
    private(set) var studioSource: StudioSource?
    /// Studio sends the DAW's windows besides its sound. Kept per Mac.
    private(set) var studioSendsScreen = StudioScreenChoice.stored()
    /// The Studio check window is open: the talk key is taken there too, to be tried.
    private(set) var studioCheckOpen = false

    private init() {
        StudioTalkKey.shared.onChange = { [weak self] held in self?.setTalkHeld(held) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStudioSources() }
            }
        }
        refreshStudioSources()
    }

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
        applyMicrophone()
    }

    /// Whether the other side hears this microphone now.
    var microphoneOpen: Bool { talkback.microphoneOpen(muted: muted, studioOn: studioOn) }

    /// Hold-to-talk is what the microphone waits for now: Studio on, not muted, key not held.
    var waitsForTalkKey: Bool { studioOn && talkback.mode == .holdToTalk && !muted }

    func setTalkbackMode(_ mode: StudioTalkbackMode) {
        mode.store()
        talkback.mode = mode
        talkback.held = false
        applyMicrophone()
    }

    func setTalkHeld(_ held: Bool) {
        guard talkback.held != held else { return }
        talkback.held = held
        applyMicrophone()
    }

    /// The microphone as mute, Studio and talkback together say. Called on each of their changes;
    /// the talk key is taken only while it is what opens the microphone.
    func applyMicrophone() {
        let inStudio = studioOn && phase?.isLive == true
        StudioTalkKey.shared.isRegistered = talkback.mode == .holdToTalk && (inStudio || studioCheckOpen)
        CallManager.shared.setMuted(!microphoneOpen)
    }

    func end() {
        CallManager.shared.endCall()
    }

    var studioAvailable: Bool { StudioFeature.isEnabled }

    /// On from the host's press (or the guest's join) until either side leaves or the call ends.
    var studioOn: Bool { CallManager.shared.studioIsOn }

    /// Why Studio cannot start or did not work, for the call window.
    var studioProblem: StudioProblem? { CallManager.shared.studioProblem }

    func toggleStudio() {
        if studioOn {
            CallManager.shared.stopStudio()
        } else {
            guard let studioSource else { return }
            // The captures read the choice back from the defaults.
            studioSource.store()
            let screen = studioSendsScreen
            Task { await CallManager.shared.startStudio(screen: screen) }
        }
    }

    func setStudioSource(_ source: StudioSource) {
        source.store()
        studioSource = source
    }

    func setStudioCheckOpen(_ open: Bool) {
        studioCheckOpen = open
        if !open { talkback.held = false }
        applyMicrophone()
    }

    func setStudioSendsScreen(_ sends: Bool) {
        StudioScreenChoice.store(sends)
        studioSendsScreen = sends
    }

    func refreshStudioSources() {
        let own = Bundle.main.bundleIdentifier
        studioSources = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own }
            .compactMap { app in
                app.bundleIdentifier.map { StudioSource(bundleID: $0, name: app.localizedName ?? $0) }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        studioSource = StudioSource.pick(stored: StudioSource.stored(), running: studioSources)
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
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
        talkback.held = false
        StudioTalkKey.shared.isRegistered = talkback.mode == .holdToTalk && studioCheckOpen
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
