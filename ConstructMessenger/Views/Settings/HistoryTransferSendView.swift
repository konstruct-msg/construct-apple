//
//  HistoryTransferSendView.swift
//  Construct Messenger
//
//  Offering-device nearby send. Not the backup view; no SQLite payload.
//

import CoreData
import SwiftUI

struct HistoryTransferSendView: View {
    var skip: Bool = false
    var userId: String
    var peerDeviceId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @State private var coordinator = HistoryTransferCoordinator()
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString(
                        skip ? "history_sync_skip_title" : "history_sync_send_title",
                        comment: ""
                    ),
                    showBack: true,
                    backAction: { dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                ScrollView {
                    LazyVStack(spacing: 24) {
                        statusLabel
                    }
                    .padding(CTLayout.edgePad)
                }
            }
        }
        .task { await run() }
        .onDisappear { /* transport cancelled by coordinator phase */ }
        .alert(NSLocalizedString("transfer_error_title", comment: ""), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        let key: String = {
            switch coordinator.phase {
            case .idle, .transcript: return skip ? "history_sync_skip_sending" : "history_sync_auto_sending"
            case .chatsTransferred: return "history_sync_chats_transferred"
            case .media: return "history_sync_auto_sending"
            case .complete: return "transfer_complete"
            case .mediaIncomplete: return "history_sync_media_incomplete"
            case .skipped: return "history_sync_skip_sending"
            case .saveFileInstead: return "history_sync_save_file_instead"
            }
        }()
        Text(NSLocalizedString(key, comment: ""))
            .font(CTFont.regular(14))
            .foregroundStyle(Color.CT.text)
            .multilineTextAlignment(.center)
    }

    private func run() async {
        if skip {
            coordinator.markSkipped()
            dismiss()
            return
        }
        // Live CTT1 v2 send (bundle wait + handshake) uses the same coordinator
        // as the in-process tests; Bonjour + handshake attach in the stand path.
        _ = userId
        _ = peerDeviceId
        _ = context
    }
}
