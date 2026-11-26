//
//  CallTranscriptRowView.swift
//  Construct Messenger
//
//  A call in the conversation (`CallTranscript`): centred like a system line, the direction's
//  symbol, what happened and how long, the time. A tap calls back. The call's facts are read from
//  the call log by the row's id; a row whose call is not in the log shows nothing.
//

import SwiftUI

struct CallTranscriptRowView: View {
    let message: TranscriptRow

    @State private var call: CallRecord?

    var body: some View {
        Group {
            if let call {
                Button { callBack(call) } label: { label(call) }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(Text(LocalizedStringKey("call_call_back")))
            }
        }
        .task(id: message.revision) { call = Self.read(message.id) }
    }

    private func label(_ call: CallRecord) -> some View {
        HStack(spacing: CTSpace.xs) {
            Image(systemName: call.directionSymbol)
                .font(CTIcon.font(CTIcon.caption, weight: .semibold))
                .foregroundStyle(call.statusColor)
                .accessibilityHidden(true)
            Text(CallTranscript.summary(for: call))
                .font(CTFont.ui(ChatUIConstants.Typography.systemSize))
                .foregroundStyle(call.status == .missed ? Color.CT.danger : Color.CT.textDim)
            Text(CallTranscript.time(of: call), style: .time)
                .font(CTFont.ui(ChatUIConstants.Typography.systemSize))
                .foregroundStyle(Color.CT.textDim)
        }
        .padding(.horizontal, ChatUIConstants.Bubble.horizontalPadding)
        .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding + 1)
        .background(CTMessageBubbleTheme.incomingBackground)
        .clipShape(CTShape.control())
        .overlay(CTShape.control().stroke(Color.CT.noise, lineWidth: ChatUIConstants.Bubble.strokeWidth))
        .frame(maxWidth: .infinity)
        .padding(.vertical, ChatUIConstants.Bubble.tightVerticalPadding)
        .contentShape(Rectangle())
    }

    private func callBack(_ call: CallRecord) {
        guard let manager = CallRuntimeProvider.makeUIManager() else { return }
        Task { await manager.startOutgoingCall(to: call.peerUserId, displayName: call.peerName, hasVideo: false) }
    }

    private static func read(_ messageId: String) -> CallRecord? {
        guard let callId = CallTranscript.callId(ofMessage: messageId) else { return nil }
        do {
            return try LocalRepositories.calls.call(callId)
        } catch {
            Log.error("Call row \(callId.prefix(8))… not read: \(error)", category: "CallHistory")
            return nil
        }
    }
}

extension CallRecord {
    /// The direction's symbol, in the conversation and on the call list.
    var directionSymbol: String {
        switch direction {
        case .outgoing: return "phone.arrow.up.right"
        case .incoming: return "phone.arrow.down.left"
        }
    }

    /// The symbol's colour: what went wrong is red (nobody answered, declined), a failure orange.
    var statusColor: Color {
        switch status {
        case .missed, .declined: return Color.CT.danger
        case .completed: return direction == .outgoing ? Color.CT.textDim : Color.CT.accent
        case .failed: return Color.CT.warning
        }
    }
}
