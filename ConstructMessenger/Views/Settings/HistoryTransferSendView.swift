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
    @State private var isWritingFile = false
    @State private var exportedFile: URL?

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
                        if let file = exportedFile {
                            Text(NSLocalizedString("history_sync_file_ready", comment: ""))
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.textDim)
                                .multilineTextAlignment(.center)
                            CTSectionGroup {
                                ShareLink(item: file) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(Color.CT.accent)
                                            .frame(minWidth: 22, alignment: .center)
                                        Text(NSLocalizedString("history_sync_share_file", comment: ""))
                                            .font(CTFont.regular(15))
                                            .foregroundStyle(Color.CT.text)
                                        Spacer()
                                    }
                                    .padding(.horizontal, CTLayout.edgePad)
                                    .frame(minHeight: CTLayout.controlHeight)
                                    .contentShape(Rectangle())
                                }
                            }
                        } else if isWritingFile {
                            HStack(spacing: CTLayout.inlinePad) {
                                ProgressView()
                                Text(NSLocalizedString("history_sync_preparing_file", comment: ""))
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                        } else if coordinator.phase == .idle || coordinator.phase == .saveFileInstead {
                            CTSectionGroup {
                                ConstructButtonRow(
                                    systemImage: "square.and.arrow.down",
                                    title: LocalizedStringKey("history_sync_save_file")
                                ) {
                                    Task { await saveFile() }
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

    // MARK: - File

    /// Seal a phase-3 snapshot to the new device and hand it to the share sheet. The new
    /// device's keys come from our own account's directory entry, checked against the Flow B
    /// QR pin when we hold one. Written on a background context; nothing here touches the
    /// view context.
    private func saveFile() async {
        isWritingFile = true
        defer { isWritingFile = false }
        do {
            let local = try HistoryChannel.localKeys()
            let peer = try await HistoryChannel.fetchPeerKeys(
                ownUserId: userId,
                peerDeviceId: peerDeviceId,
                pinnedIdentity: DeviceLinkPendingPin.peerIdentity(forDeviceId: peerDeviceId)
            )
            let background = PersistenceController.shared.container.newBackgroundContext()
            let url = try await background.perform {
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("konstruct-history-\(UUID().uuidString).cthf")
                let result = try HistoryChannel.writeFile(to: staging, peer: peer, local: local, context: background)
                let named = FileManager.default.temporaryDirectory
                    .appendingPathComponent(HistoryChannel.suggestedFileName(for: result.identity))
                try? FileManager.default.removeItem(at: named)
                try FileManager.default.moveItem(at: staging, to: named)
                return named
            }
            exportedFile = url
        } catch {
            errorMessage = HistoryTransferUserMessage.text(for: error)
        }
    }
}
