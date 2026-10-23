//
//  DesktopIncomingCallRinger.swift
//  Construct Desktop
//
//  While a call rings here: a ring every few seconds, the Dock icon bouncing and a notification
//  with Answer and Decline when the app is not in front (`IncomingCallAlert`). It follows
//  `CallManager` itself rather than a view, so a call rings with the main window closed too.
//

import AppKit
import UserNotifications

@MainActor
final class DesktopIncomingCallRinger {
    static let shared = DesktopIncomingCallRinger()

    private static let ringSound = NSSound.Name("Submarine")
    private static let ringInterval: Duration = .seconds(2.5)

    private var ringingCallId: String?
    private var ring: Task<Void, Never>?
    private var attention: Int?

    private init() {}

    /// Once, at launch: the notification's buttons, and the watch on the call state.
    func start() {
        let answer = UNNotificationAction(
            identifier: IncomingCallAlert.answerAction,
            title: NSLocalizedString("call_answer", comment: ""),
            options: [.foreground]
        )
        let decline = UNNotificationAction(
            identifier: IncomingCallAlert.declineAction,
            title: NSLocalizedString("call_decline", comment: ""),
            options: [.destructive]
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: IncomingCallAlert.category, actions: [answer, decline],
                                   intentIdentifiers: [], options: [])
        ])
        follow()
    }

    private func follow() {
        let session = withObservationTracking {
            IncomingCallAlert.ringing(CallManager.shared.state)
        } onChange: {
            Task { @MainActor in DesktopIncomingCallRinger.shared.follow() }
        }
        update(ringing: session)
    }

    private func update(ringing session: CallSession?) {
        guard session?.id != ringingCallId else { return }
        stop()
        guard let session else { return }
        ringingCallId = session.id
        Log.info("Incoming call ringing on this Mac (call_id=\(session.id.prefix(8))…) active=\(NSApp.isActive)", category: "Calls")
        ring = Task {
            while !Task.isCancelled {
                NSSound(named: Self.ringSound)?.play()
                try? await Task.sleep(for: Self.ringInterval)
            }
        }
        guard !NSApp.isActive else { return }
        attention = NSApp.requestUserAttention(.criticalRequest)
        post(session)
    }

    private func post(_ session: CallSession) {
        let content = UNMutableNotificationContent()
        content.title = session.peerName
        content.body = NSLocalizedString("call_incoming_audio", comment: "")
        content.categoryIdentifier = IncomingCallAlert.category
        content.userInfo = [IncomingCallAlert.callIdKey: session.id]
        // No sound here: the ring above is the sound, and it stops with the call.
        let request = UNNotificationRequest(
            identifier: IncomingCallAlert.notificationId(callId: session.id), content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error("Incoming call notification not posted: \(error)", category: "Calls") }
        }
    }

    private func stop() {
        ring?.cancel()
        ring = nil
        if let attention { NSApp.cancelUserAttentionRequest(attention) }
        attention = nil
        if let ringingCallId {
            let id = IncomingCallAlert.notificationId(callId: ringingCallId)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        }
        ringingCallId = nil
    }
}
