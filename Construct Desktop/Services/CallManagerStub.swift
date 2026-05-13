//
//  CallManagerStub.swift
//  Construct Desktop (macOS only)
//
//  Provides the same public interface as the iOS CallManager so that
//  DesktopChatView can reference CallManager.shared without #if guards.
//  Calls are not implemented on macOS yet (see mac-calls-stub todo).
//

import Foundation
import SwiftProtobuf

@MainActor
@Observable
final class CallManager {
    static let shared = CallManager()

    // MARK: - Nested types (mirrored from iOS CallManager)

    enum CallState: Equatable {
        case idle
        case incoming(CallSession)
        case dialing(CallSession)
        case ringing(CallSession)
        case connecting(CallSession)
        case active(CallSession)
        case ended(CallSession, EndReason)
    }

    struct CallSession: Equatable {
        enum Direction: Equatable { case incoming, outgoing }
        let id: String
        let uuid: UUID
        let peerUserId: String
        let peerName: String
        let direction: Direction
    }

    enum EndReason: Equatable {
        case hangup(Shared_Proto_Signaling_V1_HangupReason)
        case error(Shared_Proto_Signaling_V1_SignalErrorCode)
        case local(String)
    }

    // MARK: - State

    private(set) var state: CallState = .idle
    private(set) var lastError: String? = nil

    private init() {}

    // MARK: - API stubs

    func clearLastError() { lastError = nil }

    func startOutgoingCall(to userId: String, displayName: String, hasVideo: Bool = false) async {
        Log.info("📞 [macOS] Calls not implemented — ignoring outgoing call to \(userId)", category: "Calls")
    }

    func endCall() {}
    func answerIncomingCall() {}
    func declineIncomingCall() {}
    func setMuted(_ muted: Bool) {}
    func setSpeaker(_ enabled: Bool) {}

    func handleCallSignalProto(from senderUserId: String, signal: Shared_Proto_Signaling_V1_WebRTCSignal) {
        Log.info("📞 [macOS] Calls not implemented — ignoring call signal from \(senderUserId.prefix(8))…", category: "Calls")
    }

    static func decodeSignalProto(from data: Data) -> Shared_Proto_Signaling_V1_WebRTCSignal? {
        try? Shared_Proto_Signaling_V1_WebRTCSignal(serializedBytes: data)
    }
}
