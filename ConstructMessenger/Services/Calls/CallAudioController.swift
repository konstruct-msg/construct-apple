//
//  CallAudioController.swift
//  Construct Messenger
//
//  Single owner of the call audio-session lifecycle.
//
//  Before this existed, five different sites poked the same global
//  AVAudioSession / RTCAudioSession in a race: WebRTCSession.configureAudioSession
//  (category), CallKitProvider.didActivate (RTC enable), CallManager.onAudioActivated
//  (category AGAIN + setActive + dial tone), CallManager.onConnected/endActiveCall
//  (dial-tone stop), and WebRTCSession.close (setActive(false)). That fragmentation
//  is why audio was silent / echoing / dial-tone-stuck depending on call order.
//
//  Everything that touches the call audio session now flows through here. CallKit
//  and CallManager only *notify* this controller of lifecycle events; this is the
//  only writer to RTCAudioSession.isAudioEnabled and the dial tone.
//
//  Split by isolation: the methods that only touch the thread-safe global
//  AVAudioSession / RTCAudioSession are `nonisolated static` (callable from CallKit's
//  nonisolated delegate callbacks). The ringback-tone + phase state is `@MainActor`
//  instance state, driven from CallManager (already @MainActor).
//

#if os(iOS)
import Foundation
import AVFoundation
import WebRTC

@MainActor
final class CallAudioController {
    static let shared = CallAudioController()
    private init() {}

    enum Phase {
        case idle      // no call
        case dialing   // outgoing call, ringback tone plays once audio is active
        case inCall    // media connected
    }
    private(set) var phase: Phase = .idle

    // MARK: - Category (runs BEFORE CallKit fulfills the start/answer action)

    /// Configure the audio category for a call. Must run *before* `action.fulfill()`
    /// in the CallKit start/answer handlers: CallKit only reliably delivers
    /// `didActivate` when an audio-capable category is already set — without this the
    /// callee answering from the background gets a connected-but-silent call because
    /// `didActivate` (where we enable audio) is never delivered.
    ///
    /// Sets the category on `AVAudioSession` directly — NEVER on the shared
    /// `RTCAudioSessionConfiguration.webRTC()` global. Mutating that global with
    /// `.defaultToSpeaker` permanently routed all WebRTC output to the speaker
    /// (acoustic feedback). `.voiceChat` mode routes to the earpiece regardless of
    /// the `.defaultToSpeaker` option, which only acts as a fallback. Does NOT
    /// activate — CallKit owns activation.
    nonisolated static func prepareCategory() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        } catch {
            Log.error("CallAudio: setCategory failed: \(error)", category: "Calls")
        }
        try? session.setPreferredSampleRate(NetworkTiming.Calls.audioPreferredSampleRateHz)
        try? session.setPreferredIOBufferDuration(NetworkTiming.Calls.audioPreferredIOBufferDuration)
    }

    // MARK: - CallKit activation events (from CallKitProvider's nonisolated delegate)

    /// CallKit activated the AVAudioSession — hand it to WebRTC and enable I/O.
    /// With `useManualAudio = true` (set in `WebRTCRuntime.bootstrap`), audio stays
    /// disabled until `isAudioEnabled` flips here, so skipping this leaves the call
    /// connected but silent.
    nonisolated static func handleCallKitActivated(_ audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(audioSession)
        rtc.isAudioEnabled = true
        dumpRoute(label: "didActivate", audioSession: audioSession, rtc: rtc)
        Task { @MainActor in shared.startDialToneIfDialing() }
    }

    /// CallKit deactivated the AVAudioSession (call ended / interrupted).
    nonisolated static func handleCallKitDeactivated(_ audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(audioSession)
        dumpRoute(label: "didDeactivate", audioSession: audioSession, rtc: rtc)
        Task { @MainActor in DialTonePlayer.shared.stop() }
    }

    // MARK: - Call lifecycle notifications (from CallManager, @MainActor)

    /// An outgoing call has begun dialing — arm the ringback tone. It actually
    /// starts once CallKit activates audio (`handleCallKitActivated`).
    func notifyDialing() {
        phase = .dialing
    }

    /// Media (ICE/DTLS) is up. Stop the ringback tone. Safety net: if CallKit never
    /// delivered `didActivate` (a documented failure when answering from background),
    /// audio is still disabled here and the call would be silent — so enable it now.
    func notifyMediaConnected() {
        phase = .inCall
        DialTonePlayer.shared.stop()
        let rtc = RTCAudioSession.sharedInstance()
        guard !rtc.isAudioEnabled else { return }
        Log.info("CallAudio: didActivate missing at media-connected — forcing audio enable", category: "Calls")
        rtc.lockForConfiguration()
        do {
            try rtc.setActive(true)
            rtc.isAudioEnabled = true
        } catch {
            Log.error("CallAudio: fallback activation failed: \(error)", category: "Calls")
        }
        rtc.unlockForConfiguration()
    }

    /// The call is tearing down — stop the ringback tone and return to idle.
    /// AVAudioSession deactivation is driven solely by CallKit's `didDeactivate`
    /// (`WebRTCSession.close()` no longer touches the session — see its comment); this
    /// only owns the tone + phase.
    func notifyTeardown() {
        DialTonePlayer.shared.stop()
        phase = .idle
    }

    // MARK: - Private

    private func startDialToneIfDialing() {
        guard phase == .dialing else { return }
        DialTonePlayer.shared.start()
    }

    nonisolated private static func dumpRoute(label: String, audioSession: AVAudioSession, rtc: RTCAudioSession) {
        let route = audioSession.currentRoute
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        Log.info(
            "AUDIO[\(label)] AV{cat=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) sr=\(Int(audioSession.sampleRate)) in=[\(inputs)] out=[\(outputs)]} RTC{active=\(rtc.isActive) audioEnabled=\(rtc.isAudioEnabled) useManual=\(rtc.useManualAudio)}",
            category: "Calls"
        )
    }
}
#endif
