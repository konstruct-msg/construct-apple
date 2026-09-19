//
//  HistoryTransferOfferView.swift
//  Construct Messenger
//
//  New-device post-link offer: Wi-Fi / file / skip. No PIN.
//

import SwiftUI
import UniformTypeIdentifiers

struct HistoryTransferOfferView: View {
    var userId: String
    var localDeviceId: String
    var onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @State private var showReceive = false
    @State private var showImporter = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("history_sync_receive_title", comment: ""),
                    showBack: true,
                    backAction: { onSkip(); dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: CTLayout.sectionGap) {
                        Text(NSLocalizedString("history_sync_offer_message_with_media", comment: ""))
                            .font(CTFont.regular(14))
                            .foregroundStyle(Color.CT.text)
                        Text(NSLocalizedString("history_sync_empty_explanation", comment: ""))
                            .font(CTFont.regular(12))
                            .foregroundStyle(Color.CT.textDim)

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
                            ) {
                                onSkip()
                                dismiss()
                            }
                        }
                    }
                    .padding(CTLayout.edgePad)
                }
            }
        }
        .fullScreenCover(isPresented: $showReceive) {
            HistoryTransferReceiveView(userId: userId, localDeviceId: localDeviceId)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType(filenameExtension: "cthf") ?? .data]
        ) { result in
            switch result {
            case .success(let url):
                errorMessage = NSLocalizedString("history_sync_no_hybrid_key", comment: "")
                _ = url
                _ = context
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
    }
}
