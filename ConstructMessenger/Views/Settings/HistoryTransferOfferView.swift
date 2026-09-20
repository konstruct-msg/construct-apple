//
//  HistoryTransferOfferView.swift
//  Construct Messenger
//
//  New-device post-link offer: Wi-Fi / file / skip. No PIN.
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
    @State private var showReceive = false
    @State private var showImporter = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var importedSummary: HistoryImportSummary?

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("history_sync_receive_title", comment: ""),
                    showBack: true,
                    backAction: { finish() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: CTLayout.sectionGap) {
                        Text(NSLocalizedString("history_sync_offer_message_with_media", comment: ""))
                            .font(CTFont.ui(14))
                            .foregroundStyle(Color.CT.text)
                        Text(NSLocalizedString("history_sync_empty_explanation", comment: ""))
                            .font(CTFont.secondary)
                            .foregroundStyle(Color.CT.textDim)

                        if isImporting {
                            HStack(spacing: CTLayout.inlinePad) {
                                ProgressView()
                                Text(NSLocalizedString("history_sync_importing", comment: ""))
                                    .font(CTFont.body)
                                    .foregroundStyle(Color.CT.textDim)
                            }
                        } else {
                            CTSectionGroup {
                                ConstructButtonRow(
                                    systemImage: "wifi",
                                    title: LocalizedStringKey("history_sync_receive_wifi")
                                ) { showReceive = true }
                                ConstructRowDivider(indent: CTLayout.edgePad)
                                ConstructButtonRow(
                                    systemImage: "folder",
                                    title: LocalizedStringKey("history_sync_import_file")
                                ) { showImporter = true }
                                ConstructRowDivider(indent: CTLayout.edgePad)
                                ConstructButtonRow(
                                    systemImage: "forward",
                                    title: LocalizedStringKey("history_sync_offer_skip")
                                ) { finish() }
                            }
                        }
                    }
                    .padding(CTLayout.edgePad)
                }
            }
        }
        .modifier(ReceiveCover(isPresented: $showReceive, userId: userId, localDeviceId: localDeviceId))
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "cthf") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                Task { await importFile(from: url) }
            case .failure(let err):
                errorMessage = err.localizedDescription
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

/// `fullScreenCover` is iOS-only; the Desktop window is a sheet.
private struct ReceiveCover: ViewModifier {
    @Binding var isPresented: Bool
    var userId: String
    var localDeviceId: String

    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) {
            HistoryTransferReceiveView(userId: userId, localDeviceId: localDeviceId)
        }
        #else
        content.sheet(isPresented: $isPresented) {
            HistoryTransferReceiveView(userId: userId, localDeviceId: localDeviceId)
        }
        #endif
    }
}
