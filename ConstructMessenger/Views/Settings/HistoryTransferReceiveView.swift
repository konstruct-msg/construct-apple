//
//  HistoryTransferReceiveView.swift
//  Construct Messenger
//
//  New-device nearby receive. Additive import; no backup restore / restart alert.
//

import SwiftUI

struct HistoryTransferReceiveView: View {
    var userId: String
    var localDeviceId: String

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = HistoryTransferCoordinator()
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("history_sync_receive_title", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                ScrollView {
                    LazyVStack(spacing: 24) {
                        Text(NSLocalizedString(statusKey, comment: ""))
                            .font(CTFont.regular(14))
                            .foregroundStyle(Color.CT.text)
                            .multilineTextAlignment(.center)
                    }
                    .padding(CTLayout.edgePad)
                }
            }
        }
        .task { await run() }
        .alert(NSLocalizedString("transfer_error_title", comment: ""), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var statusKey: String {
        switch coordinator.phase {
        case .idle, .transcript: return "history_sync_auto_connecting"
        case .chatsTransferred: return "history_sync_chats_transferred"
        case .media: return "history_sync_auto_connecting"
        case .complete: return "transfer_complete"
        case .mediaIncomplete: return "history_sync_media_incomplete"
        case .skipped: return "history_sync_skip_sending"
        case .saveFileInstead: return "history_sync_save_file_instead"
        }
    }

    private func run() async {
        _ = userId
        _ = localDeviceId
    }
}
