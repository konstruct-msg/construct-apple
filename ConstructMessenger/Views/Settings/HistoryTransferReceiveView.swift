//
//  HistoryTransferReceiveView.swift
//  Construct Messenger
//
//  New-device nearby receive. Additive import; no backup restore / restart alert.
//
//  Starts listening as soon as it appears: whether history moves is decided on the device
//  that has it (2026-09-30). This one waits, and offers only a way out — a file, or skipping.
//

import SwiftUI

struct HistoryTransferReceiveView: View {
    var userId: String
    var localDeviceId: String
    /// Called once the offer has ended — imported, skipped, or left with Back.
    var onDone: () -> Void = {}
    /// Post-link only: the phone chose to save a file, or never answers.
    var onImportFile: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = HistoryTransferCoordinator()
    @State private var channel = HistoryNearbyChannel()
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("history_sync_receive_title", comment: ""),
                    showBack: true,
                    backAction: { onDone(); dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                ScrollView {
                    LazyVStack(spacing: 24) {
                        if isWaiting {
                            ProgressView()
                        }
                        Text(NSLocalizedString(statusKey, comment: ""))
                            .font(CTFont.ui(14))
                            .foregroundStyle(Color.CT.text)
                            .multilineTextAlignment(.center)
                        if let onImportFile, isWaiting || coordinator.phase == .saveFileInstead {
                            Text(NSLocalizedString("history_sync_empty_explanation", comment: ""))
                                .font(CTFont.secondary)
                                .foregroundStyle(Color.CT.textDim)
                                .multilineTextAlignment(.center)
                            CTSectionGroup {
                                ConstructButtonRow(
                                    systemImage: "folder",
                                    title: LocalizedStringKey("history_sync_import_file"),
                                    action: onImportFile
                                )
                                ConstructRowDivider(indent: CTLayout.edgePad)
                                ConstructButtonRow(
                                    systemImage: "forward",
                                    title: LocalizedStringKey("history_sync_offer_skip")
                                ) { onDone(); dismiss() }
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

    private var isWaiting: Bool { coordinator.phase == .idle }

    private var statusKey: String {
        switch coordinator.phase {
        case .idle: return "history_sync_waiting_for_other_device"
        case .transcript: return "history_sync_auto_connecting"
        case .chatsTransferred: return "history_sync_chats_transferred"
        case .media: return "history_sync_auto_connecting"
        case .complete: return "transfer_complete"
        case .mediaIncomplete: return "history_sync_media_incomplete"
        case .skipped: return "history_sync_skip_sending"
        case .saveFileInstead: return "history_sync_save_file_instead"
        }
    }

    /// Phase 1 on the first connection; a phase-1 manifest means media follows on a second
    /// one (K18). A skip opening ends the offer. A drop in phase 2 keeps phase-1 rows and
    /// names the Settings retry.
    private func run() async {
        defer { channel.cancel() }
        do {
            let local = try HistoryChannel.localKeys()
            let pin = DeviceLinkPendingPin.trust(forUserId: userId)
            let background = PersistenceController.shared.container.newBackgroundContext()
            var expectMedia = true
            while expectMedia {
                let outcome = try await channel.receive(local: local, pin: pin, coordinator: coordinator, context: background)
                switch outcome {
                case .skipped:
                    expectMedia = false
                case .imported(_, let manifestPhase):
                    switch manifestPhase {
                    case 1:
                        coordinator.markChatsTransferred()
                        coordinator.markMedia()
                    default:
                        coordinator.markComplete()
                        expectMedia = false
                    }
                }
            }
            DeviceLinkPendingPin.clear(forUserId: userId)
            try await Task.sleep(for: HistoryTransferCoordinator.resultHold)
            onDone()
            dismiss()
        } catch is CancellationError {
            // Sheet dismissed.
        } catch {
            Log.error("history_receive_failed phase=\(coordinator.phase) error=\(error)", category: "HistorySync")
            if coordinator.phase == .media {
                coordinator.markMediaIncomplete()
            } else {
                coordinator.markSaveFileInstead()
            }
            errorMessage = HistoryTransferUserMessage.text(for: error)
        }
    }
}
