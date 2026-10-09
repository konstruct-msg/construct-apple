//
//  HistoryTransferOfferView.swift
//  Construct Messenger
//
//  New-device post-link receive: waits for the other device; a file or Skip as ways out. No PIN.
//

import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct HistoryTransferOfferView: View {
    var userId: String
    var localDeviceId: String
    /// Called when the offer is over — skipped, or imported. The caller clears the link phase.
    var onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importedSummary: HistoryImportSummary?

    /// No question here: the device that has the history decides whether to send it
    /// (2026-09-30). This one listens straight away and keeps a file and Skip as ways out.
    var body: some View {
        HistoryTransferReceiveView(
            userId: userId,
            localDeviceId: localDeviceId,
            // The receive screen dismisses itself; `onFinish` only clears the link phase.
            onDone: onFinish,
            onImportFile: { showImporter = true }
        )
        .overlay {
            if isImporting {
                ZStack {
                    Color.CT.bg.opacity(0.9).ignoresSafeArea()
                    HStack(spacing: CTLayout.inlinePad) {
                        ProgressView()
                        Text(NSLocalizedString("history_sync_importing", comment: ""))
                            .font(CTFont.body)
                            .foregroundStyle(Color.CT.textDim)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "cthf") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                Task { await importFile(from: url) }
            case .failure(let err):
                errorMessage = err.userFacingMessage
            }
        }
        .alert(NSLocalizedString("transfer_error_title", comment: ""), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(NSLocalizedString("transfer_complete", comment: ""), isPresented: Binding(
            get: { importedSummary != nil },
            set: { if !$0 { importedSummary = nil } }
        )) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) { finish() }
        } message: {
            if let s = importedSummary {
                Text(String(format: NSLocalizedString("history_sync_imported_summary", comment: ""), s.applied))
            }
        }
    }

    private func finish() {
        onFinish()
        dismiss()
    }

    // MARK: - File import

    /// Copy the picked file out of its security scope, verify + decapsulate + import on a
    /// background context. Any refusal leaves the copy in place for a retry; success deletes it.
    private func importFile(from picked: URL) async {
        isImporting = true
        defer { isImporting = false }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let local: HistoryLocalKeys
        let staging: URL
        do {
            local = try HistoryChannel.localKeys()
            staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("konstruct-import-\(UUID().uuidString).cthf")
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: picked, to: staging)
        } catch {
            errorMessage = HistoryTransferUserMessage.text(for: error)
            return
        }
        let context = PersistenceController.shared.container.newBackgroundContext()
        do {
            let summary = try await HistoryChannel.importFile(
                at: staging,
                local: local,
                pin: DeviceLinkPendingPin.trust(forUserId: userId),
                context: context
            )
            DeviceLinkPendingPin.clear(forUserId: userId)
            importedSummary = summary
        } catch {
            errorMessage = HistoryTransferUserMessage.text(for: error)
        }
    }
}
