//
//  HistoryTransferStages.swift
//  Construct Messenger
//
//  What a history transfer shows while it runs, on either device: one line saying where it is,
//  and the two stages — chats, then photos and files — each waiting, under way, done or stopped.
//  The phase is `HistoryTransferCoordinator`'s; this file only reads it.
//

import SwiftUI

enum HistoryTransferStage: CaseIterable {
    case chats
    case media

    enum Status: Equatable {
        case waiting
        case active
        case done
        case stopped
    }

    var titleKey: String {
        switch self {
        case .chats: return "history_sync_stage_chats"
        case .media: return "history_sync_stage_media"
        }
    }

    /// A failure before media began is a failure of the chats: the coordinator records only
    /// "save a file instead", and media never starts without the chats.
    func status(in phase: HistoryTransferPhase) -> Status {
        switch (self, phase) {
        case (_, .idle), (_, .skipped): return .waiting
        case (.chats, .transcript): return .active
        case (.chats, .saveFileInstead): return .stopped
        case (.chats, _): return .done
        case (.media, .transcript), (.media, .saveFileInstead): return .waiting
        // The receiver marks chats done and media started in one step; the sender opens the
        // media connection right after the chats one closes.
        case (.media, .chatsTransferred), (.media, .media): return .active
        case (.media, .complete): return .done
        case (.media, .mediaIncomplete): return .stopped
        }
    }
}

enum HistoryTransferSide {
    case sending
    case receiving

    func statusKey(in phase: HistoryTransferPhase) -> String {
        switch phase {
        case .idle:
            return self == .sending ? "history_sync_looking" : "history_sync_waiting_for_other_device"
        case .transcript, .chatsTransferred, .media:
            return self == .sending ? "history_sync_auto_sending" : "history_sync_auto_connecting"
        case .complete: return "history_sync_done"
        case .mediaIncomplete: return "history_sync_media_incomplete"
        case .skipped: return "history_sync_skip_sending"
        case .saveFileInstead: return "history_sync_save_file_instead"
        }
    }
}

/// The status line and the stage rows. `stages` narrows a Settings retry to the one it sends.
struct HistoryTransferProgress: View {
    let phase: HistoryTransferPhase
    let side: HistoryTransferSide
    var stages: [HistoryTransferStage] = HistoryTransferStage.allCases

    var body: some View {
        VStack(spacing: CTLayout.sectionGap) {
            Text(NSLocalizedString(side.statusKey(in: phase), comment: ""))
                .font(CTFont.body)
                .foregroundStyle(Color.CT.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            if phase != .skipped {
                CTSectionGroup {
                    ForEach(Array(stages.enumerated()), id: \.element) { index, stage in
                        if index > 0 { ConstructRowDivider(indent: CTLayout.edgePad) }
                        StageRow(stage: stage, status: stage.status(in: phase))
                    }
                }
            }
        }
    }

    private struct StageRow: View {
        let stage: HistoryTransferStage
        let status: HistoryTransferStage.Status

        var body: some View {
            HStack(spacing: CTLayout.edgePad) {
                Text(NSLocalizedString(stage.titleKey, comment: ""))
                    .font(CTFont.body)
                    .foregroundStyle(status == .waiting ? Color.CT.textDim : Color.CT.text)
                Spacer()
                indicator
                    .frame(minWidth: CTLayout.hitTarget, alignment: .trailing)
            }
            .padding(.horizontal, CTLayout.edgePad)
            .frame(minHeight: CTLayout.controlHeight)
            .accessibilityElement(children: .combine)
        }

        @ViewBuilder
        private var indicator: some View {
            switch status {
            case .waiting:
                Image(systemName: "circle")
                    .font(CTIcon.font(CTIcon.row))
                    .foregroundStyle(Color.CT.textDim)
            case .active:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(CTIcon.font(CTIcon.row))
                    .foregroundStyle(Color.CT.accent)
            case .stopped:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(CTIcon.font(CTIcon.row))
                    .foregroundStyle(Color.CT.danger)
            }
        }
    }
}
