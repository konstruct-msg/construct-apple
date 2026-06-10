//
//  CallKitProvider.swift
//  Construct Messenger
//

#if os(iOS)
import Foundation
import CallKit
import AVFoundation
import WebRTC

final class CallKitProvider: NSObject, CXProviderDelegate {
    static let shared = CallKitProvider()

    private let provider: CXProvider
    private let callController = CXCallController()
    var onAnswer: (@Sendable (UUID) -> Void)?
    var onEnd: (@Sendable (UUID) -> Void)?
    /// Called when CallKit activates the audio session (safe to start audio output).
    var onAudioActivated: (@Sendable () -> Void)?
    /// Called when CallKit deactivates the audio session.
    var onAudioDeactivated: (@Sendable () -> Void)?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Thread-safe synchronous variant for use directly inside PushKit's
    /// `pushRegistry(_:didReceiveIncomingPushWith:)` delegate callback.
    /// iOS 13+ terminates the app if `reportNewIncomingCall` is not called
    /// before returning from (or dispatching away from) that callback.
    /// `CXProvider.reportNewIncomingCall` is documented as thread-safe.
    nonisolated func reportIncomingCallSync(callId: String, callerId: String, callerName: String, hasVideo: Bool) -> UUID {
        let uuid = UUID(uuidString: callId) ?? UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerId)
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                Log.error("CallKit reportNewIncomingCall failed: \(error)", category: "Calls")
            } else {
                Log.info("CallKit incoming call reported sync (uuid=\(uuid.uuidString.prefix(8))…)", category: "Calls")
            }
        }
        return uuid
    }

    @MainActor
    func reportIncomingCall(callId: String, callerId: String, callerName: String, hasVideo: Bool) -> UUID {
        let uuid = UUID(uuidString: callId) ?? UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerId)
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                Log.error("CallKit reportNewIncomingCall failed: \(error)", category: "Calls")
            } else {
                Log.info("CallKit incoming call reported (uuid=\(uuid.uuidString.prefix(8))…)", category: "Calls")
            }
        }
        return uuid
    }

    @MainActor
    func updateCallInfo(uuid: UUID, callerName: String) {
        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        provider.reportCall(with: uuid, updated: update)
    }

    @MainActor
    func requestEndCall(uuid: UUID) async {
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        do {
            try await callController.request(transaction)
        } catch {
            Log.error("CallKit end-call transaction failed: \(error)", category: "Calls")
        }
    }

    @MainActor
    func requestStartCall(uuid: UUID, calleeId: String, calleeName: String, hasVideo: Bool) async throws {
        let handle = CXHandle(type: .generic, value: calleeId)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = hasVideo
        action.contactIdentifier = calleeId

        let transaction = CXTransaction(action: action)
        do {
            try await callController.request(transaction)
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
            // Set the callee's display name so the lock screen shows a human-readable name
            // instead of the raw server UUID that CallKit falls back to for the handle value.
            let update = CXCallUpdate()
            update.localizedCallerName = calleeName
            provider.reportCall(with: uuid, updated: update)
            Log.info("CallKit start-call transaction ok (uuid=\(uuid.uuidString.prefix(8))…)", category: "Calls")
        } catch {
            Log.error("CallKit start-call transaction failed: \(error)", category: "Calls")
            throw error
        }
    }

    @MainActor
    func reportOutgoingCallConnected(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    @MainActor
    func reportCallEnded(uuid: UUID) {
        provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    }

    // MARK: - CXProviderDelegate

    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Log.info("CallKit audio session activated", category: "Calls")
        // WebRTC iOS SDK runs its own RTCAudioSession that gates audio I/O. With
        // `useManualAudio = true` (set in WebRTCFactory), the I/O stays disabled
        // until we explicitly hand over the activated AVAudioSession and flip
        // `isAudioEnabled`. Skipping this leaves the call connected but silent.
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(audioSession)
        rtc.isAudioEnabled = true
        let route = audioSession.currentRoute
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        Log.info(
            "AUDIO[didActivate] AV{cat=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) sr=\(Int(audioSession.sampleRate)) in=[\(inputs)] out=[\(outputs)]} RTC{active=\(rtc.isActive) audioEnabled=\(rtc.isAudioEnabled) useManual=\(rtc.useManualAudio)}",
            category: "Calls"
        )
        onAudioActivated?()
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Log.info("CallKit audio session deactivated", category: "Calls")
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(audioSession)
        onAudioDeactivated?()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Log.info("CallKit start (uuid=\(action.callUUID.uuidString.prefix(8))…)", category: "Calls")
        Self.prepareAudioSessionForCall()
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Log.info("CallKit answer (uuid=\(action.callUUID.uuidString.prefix(8))…)", category: "Calls")
        // Configure WebRTC's audio session category BEFORE fulfilling the answer.
        // When the callee answers from the background/lock screen (the normal case
        // for an incoming VoIP call), CallKit only reliably delivers `didActivate`
        // if an audio-capable category is already set on the RTCAudioSession. Our
        // own `configureAudioSession()` runs later, asynchronously inside `answer()`
        // → `ensureWebRTC()` — too late. Without this, the first push-woken call
        // connects (ICE → connected) but stays silent both ways because the
        // `didActivate` callback (where we flip `isAudioEnabled`) is never delivered.
        Self.prepareAudioSessionForCall()
        onAnswer?(action.callUUID)
        action.fulfill()
    }

    /// Pre-set the RTCAudioSession category/mode so CallKit reliably activates audio.
    /// Does NOT activate the session — CallKit still owns activation via `didActivate`.
    nonisolated static func prepareAudioSessionForCall() {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        do {
            try rtc.setConfiguration(config)
        } catch {
            Log.error("Failed to pre-configure RTCAudioSession: \(error)", category: "Calls")
        }
        rtc.unlockForConfiguration()
    }

    /// Safety net for the documented CallKit bug where `didActivate` is never
    /// delivered for a backgrounded answer. Call once the media path is up
    /// (ICE connected): if audio is still disabled, CallKit dropped the callback,
    /// so activate the WebRTC audio session ourselves. No-op when `didActivate`
    /// already enabled audio (the normal path), so it never fights CallKit.
    @MainActor
    func activateAudioIfNeeded() {
        let rtc = RTCAudioSession.sharedInstance()
        guard !rtc.isAudioEnabled else { return }
        Log.info("AUDIO[fallback] didActivate not delivered by ICE-connected — forcing activation", category: "Calls")
        rtc.lockForConfiguration()
        do {
            try rtc.setActive(true)
            rtc.isAudioEnabled = true
        } catch {
            Log.error("Fallback audio activation failed: \(error)", category: "Calls")
        }
        rtc.unlockForConfiguration()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Log.info("CallKit end (uuid=\(action.callUUID.uuidString.prefix(8))…)", category: "Calls")
        onEnd?(action.callUUID)
        action.fulfill()
    }
}

#endif
