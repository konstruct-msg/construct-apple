//
//  CallKitProvider.swift
//  Construct Messenger
//

#if os(iOS)
import Foundation
import CallKit
import AVFoundation
import UIKit
import Synchronization

/// The delegate runs on CallKit's own queue (`setDelegate(_:queue: nil)`), never the main one.
/// `@unchecked`: `provider` and `callController` are CallKit's thread-safe objects; the handlers,
/// set from the main actor and read on that queue, live in a `Mutex`.
final class CallKitProvider: NSObject, CXProviderDelegate, @unchecked Sendable {
    static let shared = CallKitProvider()

    private let provider: CXProvider
    private let callController = CXCallController()

    private struct Handlers {
        var onAnswer: (@Sendable (UUID) -> Void)?
        var onEnd: (@Sendable (UUID) -> Void)?
    }
    private let handlers = Mutex(Handlers())
    var onAnswer: (@Sendable (UUID) -> Void)? {
        get { handlers.withLock { $0.onAnswer } }
        set { handlers.withLock { $0.onAnswer = newValue } }
    }
    var onEnd: (@Sendable (UUID) -> Void)? {
        get { handlers.withLock { $0.onEnd } }
        set { handlers.withLock { $0.onEnd = newValue } }
    }

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

    /// The offer's word on whether the call is video, over the push's.
    func updateCallHasVideo(uuid: UUID, hasVideo: Bool) {
        let update = CXCallUpdate()
        update.hasVideo = hasVideo
        provider.reportCall(with: uuid, updated: update)
    }

    /// Answer a ringing call from the app's own screen, as the system's button would. False when
    /// CallKit refused, and the caller answers past it.
    @MainActor
    func requestAnswerCall(uuid: UUID) async -> Bool {
        do {
            try await callController.request(CXTransaction(action: CXAnswerCallAction(call: uuid)))
            return true
        } catch {
            Log.error("CallKit answer transaction failed: \(error)", category: "Calls")
            return false
        }
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
        CallAudioController.handleCallKitActivated(audioSession)
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Log.info("CallKit audio session deactivated", category: "Calls")
        CallAudioController.handleCallKitDeactivated(audioSession)
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Log.info("CallKit start (uuid=\(action.callUUID.uuidString.prefix(8))…)", category: "Calls")
        // Set the audio category before fulfilling so CallKit reliably activates audio.
        CallAudioController.prepareCategory()
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Log.info("CallKit answer (uuid=\(action.callUUID.uuidString.prefix(8))…)", category: "Calls")
        // Set the audio category before fulfilling. Critical for the callee answering
        // from background/lock screen: without it CallKit drops `didActivate` and the
        // connected call is silent. See CallAudioController.prepareCategory.
        CallAudioController.prepareCategory()
        onAnswer?(action.callUUID)
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // The app's state is UIKit's, readable only on the main actor; this runs on CallKit's
        // queue, so the line is written from there a moment later.
        let uuid = action.callUUID.uuidString.prefix(8)
        Task { @MainActor in
            Log.info("CallKit end (uuid=\(uuid)…) \(Self.currentAppContext())", category: "Calls")
        }
        onEnd?(action.callUUID)
        action.fulfill()
    }

    @MainActor
    private static func currentAppContext() -> String {
        let app = UIApplication.shared
        let sceneStates = app.connectedScenes
            .map { $0.activationState.debugName }
            .sorted()
            .joined(separator: ",")
        return "appState=\(app.applicationState.debugName) protectedData=\(app.isProtectedDataAvailable) scenes=[\(sceneStates)]"
    }
}

private extension UIApplication.State {
    var debugName: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

private extension UIScene.ActivationState {
    var debugName: String {
        switch self {
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        case .unattached: return "unattached"
        @unknown default: return "unknown"
        }
    }
}

#endif
