//
//  IncomingCallAlert.swift
//  Construct Messenger
//
//  How a Mac makes an incoming call heard. iOS has CallKit; on a Mac the incoming panel lived
//  inside the main window and nothing else said a call was ringing — with the app behind other
//  windows, a call rang unseen and unheard until the caller gave up (2026-10-23, a call from
//  Android). The Desktop rings, bounces the Dock icon and posts a notification with Answer and
//  Decline while a call is `.incoming`; these are the decisions it takes, apart from AppKit.
//

import Foundation

enum IncomingCallAlert {
    static let category = "INCOMING_CALL"
    static let answerAction = "INCOMING_CALL_ANSWER"
    static let declineAction = "INCOMING_CALL_DECLINE"
    static let callIdKey = "callId"

    static func notificationId(callId: String) -> String { "call-incoming-\(callId)" }

    /// The call that should be ringing in this state, or nil.
    static func ringing(_ state: CallState) -> CallSession? {
        if case .incoming(let session) = state { return session }
        return nil
    }

    enum Response: Equatable {
        case answer, decline, open, ignore
    }

    /// What a press on the notification does. Answer and Decline act only on the call the
    /// notification was posted for and only while it still rings — a banner left in Notification
    /// Center from an earlier call must not answer the next one. A plain click brings the app
    /// forward whatever the call has become.
    static func response(action: String, notificationCallId: String?, ringingCallId: String?) -> Response {
        switch action {
        case answerAction, declineAction:
            guard let notificationCallId, notificationCallId == ringingCallId else { return .ignore }
            return action == answerAction ? .answer : .decline
        default:
            return .open
        }
    }
}
