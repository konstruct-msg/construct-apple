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
    @State private var channel = HistoryNearbyChannel()
    @State private var errorMessage: String?
    @State private var isWritingFile = false
    @State private var exportedFile: URL?

    /// How long the other device may go unseen before the screen says what is needed and
    /// offers a file. Neither side gives up on its own: the person may still be walking over.
    static let notSeenAfter: Duration = .seconds(20)
    @State private var peerNotSeen = false

    private var isSkip: Bool { skip || kind == .skip }

    private var stages: [HistoryTransferStage] {
        switch kind {
        case .chatsOnly: return [.chats]
        case .mediaOnly: return [.media]
        case .nearby, .skip: return HistoryTransferStage.allCases
        }
    }

    /// The file is the way out, not a second choice beside Wi-Fi: offered once the other device
    /// has gone unseen, or the transfer stopped.
    private var offersFile: Bool {
        switch coordinator.phase {
        case .saveFileInstead, .mediaIncomplete: return true
        case .idle: return peerNotSeen
        default: return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: CTLayout.sectionGap) {
                if isSkip {
                    Text(NSLocalizedString("history_sync_skip_sending", comment: ""))
                        .font(CTFont.body)
                        .foregroundStyle(Color.CT.text)
                        .multilineTextAlignment(.center)
                } else {
                    HistoryTransferProgress(phase: coordinator.phase, side: .sending, stages: stages)
                    if coordinator.phase == .idle, peerNotSeen {
                        hint("history_sync_not_seen_hint")
                    }
                    fileSection
                }
            }
            .padding(CTLayout.edgePad)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .screenTitle(NSLocalizedString(isSkip ? "history_sync_skip_title" : "history_sync_send_title", comment: ""))
        .task { await run() }
        .task {
            try? await Task.sleep(for: Self.notSeenAfter)
            if coordinator.phase == .idle { peerNotSeen = true }
        }
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
    private var fileSection: some View {
        if let file = exportedFile {
            hint("history_sync_file_ready")
            CTSectionGroup {
                ShareLink(item: file) {
                    HStack(spacing: CTLayout.edgePad) {
                        Image(systemName: "square.and.arrow.up")
                            .font(CTIcon.font(CTIcon.row))
                            .foregroundStyle(Color.CT.accent)
                        Text(NSLocalizedString("history_sync_share_file", comment: ""))
                            .font(CTFont.body)
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
                    .font(CTFont.body)
                    .foregroundStyle(Color.CT.textDim)
            }
        } else if offersFile {
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

    private func hint(_ key: String) -> some View {
        Text(NSLocalizedString(key, comment: ""))
            .font(CTFont.secondary)
            .foregroundStyle(Color.CT.textDim)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// Post-link: transcript, then media, each on its own connection (K18). Settings retry runs
    /// one phase. Skip is a CTT1 v2 opening of type 0x03 so the new device's receive screen
    /// finishes instead of waiting; a receiver that is not listening costs one short wait.
    private func run() async {
        defer { channel.cancel() }
        if skip || kind == .skip {
            await sendSkip()
            dismiss()
            return
        }
        do {
            let local = try HistoryChannel.localKeys()
            let peer = try await HistoryNearbyChannel.waitForPeerKeys(
                ownUserId: userId,
                peerDeviceId: peerDeviceId,
                pinnedIdentity: DeviceLinkPendingPin.peerIdentity(forDeviceId: peerDeviceId)
            )
            let background = PersistenceController.shared.container.newBackgroundContext()
            switch kind {
            case .nearby:
                try await channel.offer(.transcript, peer: peer, local: local, coordinator: coordinator, context: background)
                try await channel.offer(.media, peer: peer, local: local, coordinator: coordinator, context: background)
            case .chatsOnly:
                try await channel.offer(.transcript, peer: peer, local: local, coordinator: coordinator, context: background)
                coordinator.markComplete()
            case .mediaOnly:
                try await channel.offer(.media, peer: peer, local: local, coordinator: coordinator, context: background)
            case .skip:
                break
            }
            DeviceLinkPendingPin.clearPeerIdentity(forDeviceId: peerDeviceId)
            if coordinator.phase == .complete {
                try await Task.sleep(for: HistoryTransferCoordinator.resultHold)
                dismiss()
            }
        } catch is CancellationError {
            // Sheet dismissed.
        } catch {
            Log.error("history_send_failed kind=\(kind) error=\(error)", category: "HistorySync")
            if coordinator.phase != .mediaIncomplete { coordinator.markSaveFileInstead() }
            errorMessage = HistoryTransferUserMessage.text(for: error)
        }
    }

    private static let skipWait: Duration = .seconds(15)

    private func sendSkip() async {
        guard let local = try? HistoryChannel.localKeys(),
              let peer = try? await HistoryChannel.fetchPeerKeys(
                ownUserId: userId,
                peerDeviceId: peerDeviceId,
                pinnedIdentity: DeviceLinkPendingPin.peerIdentity(forDeviceId: peerDeviceId)
              )
        else {
            coordinator.markSkipped()
            return
        }
        let background = PersistenceController.shared.container.newBackgroundContext()
        let channel = self.channel
        let coordinator = self.coordinator
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try? await channel.offer(.skip, peer: peer, local: local, coordinator: coordinator, context: background)
            }
            group.addTask {
                try? await Task.sleep(for: Self.skipWait)
            }
            await group.next()
            group.cancelAll()
        }
        channel.cancel()
        coordinator.markSkipped()
        DeviceLinkPendingPin.clearPeerIdentity(forDeviceId: peerDeviceId)
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
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("konstruct-history-\(UUID().uuidString).cthf")
            let result = try await HistoryChannel.writeFile(to: staging, peer: peer, local: local, context: background)
            let named = FileManager.default.temporaryDirectory
                .appendingPathComponent(HistoryChannel.suggestedFileName(forSnapshot: result.snapshotId))
            try? FileManager.default.removeItem(at: named)
            try FileManager.default.moveItem(at: staging, to: named)
            exportedFile = named
        } catch {
            errorMessage = HistoryTransferUserMessage.text(for: error)
        }
    }
}
