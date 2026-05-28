//
//  CryptoManager+OrchestratorLogging.swift
//  Construct Messenger
//
//  Orchestrator event/action logging helpers extracted from CryptoManager.
//  Kept in a separate file to avoid inflating the core class.
//

import Foundation

extension CryptoManager {

    // MARK: - Orchestrator Logging

    func logOrchestratorEvent(_ event: CfeIncomingEvent, actions: [CfeAction], tag: String?) {
        // Keep this log terse: file logging is always enabled (Diagnostics).
        // Only log at debug level unless it looks like a session-health transition.
        let summary = orchestratorEventSummary(event)
        let actionSummary = orchestratorActionSummary(actions)
        let full = summary + " actions=\(actions.count)" + (actionSummary.isEmpty ? "" : " \(actionSummary)") + (tag.map { " tag=\($0)" } ?? "")

        if actions.contains(where: { action in
            switch action {
            case .sendEndSession, .sessionHealNeeded, .fetchPublicKeyBundle:
                return true
            default:
                return false
            }
        }) {
            Log.info("ORCH_EVENT: \(full)", category: "CryptoOrchestrator")
        } else {
            Log.debug("ORCH_EVENT: \(full)", category: "CryptoOrchestrator")
        }
    }

    func orchestratorEventSummary(_ event: CfeIncomingEvent) -> String {
        switch event {
        case .messageReceived(let messageId, let from, let data, let msgNum, _, let otpkId, let isControl, let contentType):
            return "messageReceived from=\(from.prefix(8))… msgId=\(messageId.prefix(8))… msgNum=\(msgNum) ct=\(contentType) control=\(isControl) data=\(data.count)B otpkId=\(otpkId)"
        case .outgoingMessage(let contactId, let messageId, let plaintextUtf8, let contentType):
            return "outgoingMessage to=\(contactId.prefix(8))… msgId=\(messageId.prefix(8))… ct=\(contentType) plaintext=\(plaintextUtf8.count)ch"
        case .outgoingCallSignal(let contactId, let messageId, let protoBytes):
            return "outgoingCallSignal to=\(contactId.prefix(8))… msgId=\(messageId.prefix(8))… proto=\(protoBytes.count)B"
        case .sessionInitCompleted(let contactId, let sessionData):
            return "sessionInitCompleted contactId=\(contactId.prefix(8))… session=\(sessionData.count)B"
        case .ackReceived(let messageId):
            return "ackReceived msgId=\(messageId.prefix(8))…"
        case .sessionLoaded(let key, let data):
            return "sessionLoaded key=\(key.prefix(24))… data=\(data?.count ?? 0)B"
        case .keyBundleFetched(let userId, _):
            return "keyBundleFetched userId=\(userId.prefix(8))…"
        case .networkReconnected:
            return "networkReconnected"
        case .appLaunched:
            return "appLaunched"
        case .timerFired(let timerId):
            return "timerFired id=\(timerId.prefix(24))…"
        case .ackDbResult(let messageId, let isProcessed):
            return "ackDbResult msgId=\(messageId.prefix(8))… processed=\(isProcessed)"
        case .activeChatChanged(let contactId, let isActive):
            return "activeChatChanged contactId=\(contactId.prefix(8))… active=\(isActive)"
        case .heartbeatReceived(let contactId, let messageId, let data, let msgNum):
            return "heartbeatReceived from=\(contactId.prefix(8))… msgId=\(messageId.prefix(8))… msgNum=\(msgNum) data=\(data.count)B"
        }
    }

    private func orchestratorActionSummary(_ actions: [CfeAction]) -> String {
        var labels = Set<String>()
        var firstError: (String, String)?
        for action in actions {
            switch action {
            case .messageDecrypted:         labels.insert("decrypted")
            case .callSignalDecrypted:      labels.insert("call_signal")
            case .sendEncryptedMessage:     labels.insert("send")
            case .saveSessionToSecureStore: labels.insert("save")
            case .sessionHealNeeded:        labels.insert("heal")
            case .sendEndSession:           labels.insert("end_session")
            case .fetchPublicKeyBundle:     labels.insert("fetch_bundle")
            case .notifyError(let code, let msg) where firstError == nil:
                firstError = (code, msg)
            default: break
            }
        }
        if let (code, msg) = firstError { labels.insert("error[\(code)]=\(msg.prefix(80))") }
        return labels.isEmpty ? "" : "flags=\(labels.sorted().joined(separator: ","))"
    }
}
