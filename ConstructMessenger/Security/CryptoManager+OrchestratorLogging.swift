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
            case .sendDecryptionError, .sessionRetired, .resendMessage, .openReceiving, .openSession:
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
        case .messageReceived(let messageId, let from, let data, let contentType, let certificate):
            return "messageReceived from=\(from.prefix(8))… msgId=\(messageId.prefix(8))… ct=\(contentType) data=\(data.count)B sealed=\(certificate != nil)"
        case .outgoingMessage(let contactId, let messageId, let plaintextUtf8, let contentType):
            return "outgoingMessage to=\(contactId.prefix(8))… msgId=\(messageId.prefix(8))… ct=\(contentType) plaintext=\(plaintextUtf8.count)ch"
        case .outgoingCallSignal(let contactId, let messageId, let protoBytes):
            return "outgoingCallSignal to=\(contactId.prefix(8))… msgId=\(messageId.prefix(8))… proto=\(protoBytes.count)B"
        case .sessionInitCompleted(let contactId, let sessionData):
            return "sessionInitCompleted contactId=\(contactId.prefix(8))… session=\(sessionData.count)B"
        case .ackReceived(let messageId):
            return "ackReceived msgId=\(messageId.prefix(8))…"
        case .sessionBundleFetched(let contactId, _):
            return "sessionBundleFetched contactId=\(contactId.prefix(8))…"
        case .sessionBundleUnavailable(let contactId):
            return "sessionBundleUnavailable contactId=\(contactId.prefix(8))…"
        case .networkReconnected:
            return "networkReconnected"
        case .appLaunched:
            return "appLaunched"
        case .decryptionErrorReceived(let contactId, let payload):
            return "decryptionErrorReceived from=\(contactId.prefix(8))… payload=\(payload.count)B"
        case .timerFired(let timerId):
            return "timerFired id=\(timerId.prefix(24))…"
        case .ackDbResult(let messageId, let isProcessed):
            return "ackDbResult msgId=\(messageId.prefix(8))… processed=\(isProcessed)"
        case .heartbeatReceived(let contactId, let messageId, let data):
            return "heartbeatReceived from=\(contactId.prefix(8))… msgId=\(messageId.prefix(8))… data=\(data.count)B"
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
            case .saveToSecureStore: labels.insert("save")
            case .sendDecryptionError:      labels.insert("decryption_error")
            case .sessionRetired:           labels.insert("retired")
            case .resendMessage:            labels.insert("resend")
            case .openReceiving:            labels.insert("open_receiving")
            case .openSession:              labels.insert("open_session")
            case .notifyError(let code, let msg) where firstError == nil:
                firstError = (code, msg)
            default: break
            }
        }
        if let (code, msg) = firstError { labels.insert("error[\(code)]=\(msg.prefix(80))") }
        return labels.isEmpty ? "" : "flags=\(labels.sorted().joined(separator: ","))"
    }
}
