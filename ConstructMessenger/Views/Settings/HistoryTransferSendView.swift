//
//  HistoryTransferSendView.swift
//  Construct Messenger
//
//  Offering-device nearby send. Not the backup view; no SQLite payload.
//

import CoreData
import SwiftUI

struct HistoryTransferSendView: View {
    enum Kind: String, Identifiable {
        case nearby
        case skip
        case chatsOnly
        case mediaOnly
        var id: String { rawValue }
    }

    var kind: Kind = .nearby
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
                    title: NSLocalizedString(titleKey, comment: ""),
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
                        if coordinator.phase == .idle || coordinator.phase == .saveFileInstead {
                            CTSectionGroup {
                                ConstructButtonRow(
                                    systemImage: "square.and.arrow.down",
                                    title: LocalizedStringKey("history_sync_save_file")
                                ) {
                                    errorMessage = NSLocalizedString("history_sync_no_hybrid_key", comment: "")
                                }
                            }
                        }
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

    private var titleKey: String {
        if skip || kind == .skip { return "history_sync_skip_title" }
        switch kind {
        case .chatsOnly: return "history_sync_settings_chats"
        case .mediaOnly: return "history_sync_settings_media"
        case .nearby, .skip: return "history_sync_send_title"
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        let key: String = {
            switch coordinator.phase {
            case .idle, .transcript:
                return (skip || kind == .skip) ? "history_sync_skip_sending" : "history_sync_auto_sending"
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
        if skip || kind == .skip {
            coordinator.markSkipped()
            dismiss()
            return
        }
        _ = userId
        _ = peerDeviceId
        _ = context
    }
}
