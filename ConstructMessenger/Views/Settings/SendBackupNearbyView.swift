//
//  SendBackupNearbyView.swift
//  Construct Messenger
//
//  Sends a backup or history sync payload to a nearby device over P2P WiFi.
//  Uses NearbyTransferService (mode .backup for backup, .historySync for device transfer).
//

import SwiftUI
import CoreData

struct SendBackupNearbyView: View {
    enum Mode {
        case backup
        case historySync
        case historySyncSkip
    }

    var mode: Mode = .backup
    /// When set (post–device-link history sync), sender uses the shared PIN — no display step.
    var autoPairingPIN: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context

    @State private var service = NearbyTransferService()
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var hasPreparedTransfer = false

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
                content
            }
        }
        .task {
            guard !hasPreparedTransfer else { return }
            hasPreparedTransfer = true
            await prepare()
        }
        .onDisappear { service.cancel() }
        .alert(NSLocalizedString("transfer_error_title", comment: ""), isPresented: $showError) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: service.transferState) { _, newState in
            if mode == .historySyncSkip, case .complete = newState {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                switch service.transferState {
                case .idle, .preparing:
                    preparingView
                case .advertising:
                    if autoPairingPIN != nil {
                        statusView(
                            systemImage: "paperplane",
                            label: NSLocalizedString(autoSendingKey, comment: "")
                        )
                    } else {
                        advertisingView
                    }
                case .browsing, .handshaking:
                    statusView(
                        systemImage: "arrow.left.arrow.right",
                        label: NSLocalizedString("transfer_connecting", comment: "")
                    )
                case .transferring:
                    transferringView
                case .complete:
                    completeView
                case .failed(let msg):
                    failedView(msg)
                }
            }
            .padding(20)
        }
    }

    private var preparingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.CT.accent)
            Text(NSLocalizedString("transfer_preparing", comment: ""))
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
        }
        .padding(.top, 40)
    }

    private var advertisingView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(NSLocalizedString("transfer_your_pin", comment: "").uppercased())
                    .font(CTFont.regular(11))
                    .tracking(3)
                    .foregroundColor(Color.CT.textDim)

                // Format PIN as "XXX XXX"
                Text(formattedPIN)
                    .font(CTFont.bold(36))
                    .tracking(8)
                    .foregroundColor(Color.CT.accent)
                    .monospacedDigit()
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .overlay(
                Rectangle()
                    .stroke(Color.CT.noise, lineWidth: 1)
            )

            Text(NSLocalizedString("transfer_waiting", comment: ""))
                .font(CTFont.regular(12))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)

            ProgressView()
                .tint(Color.CT.accent)
        }
        .padding(.top, 32)
    }

    private var transferringView: some View {
        VStack(spacing: 16) {
            Text(NSLocalizedString("transfer_progress", comment: "").uppercased())
                .font(CTFont.regular(11))
                .tracking(3)
                .foregroundColor(Color.CT.textDim)

            GeometryReader { geo in
                Rectangle()
                    .fill(Color.CT.noise)
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.CT.accent)
                            .frame(width: geo.size.width * service.progress, height: 4)
                    }
            }
            .frame(height: 4)

            Text("\(Int(service.progress * 100))%")
                .font(CTFont.bold(20))
                .foregroundColor(Color.CT.text)
                .monospacedDigit()
        }
        .padding(.top, 40)
    }

    private var completeView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(Color.CT.accent)
            Text(NSLocalizedString("transfer_complete", comment: ""))
                .font(CTFont.bold(15))
                .foregroundColor(Color.CT.text)
            Button(NSLocalizedString("close", comment: "")) { dismiss() }
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.accent)
                .padding(.top, 8)
        }
        .padding(.top, 40)
    }

    private func statusView(systemImage: String, label: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Color.CT.accent)
            Text(label)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
            ProgressView().tint(Color.CT.accent)
        }
        .padding(.top, 40)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(CTFont.regular(28))
                .foregroundColor(Color.CT.danger)
            Text(message)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.danger)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("close", comment: "")) { dismiss() }
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.accent)
                .padding(.top, 8)
        }
        .padding(.top, 40)
    }

    // MARK: - Logic

    private var titleKey: String {
        switch mode {
        case .backup:
            return "transfer_send_title"
        case .historySync:
            return "history_sync_send_title"
        case .historySyncSkip:
            return "history_sync_skip_title"
        }
    }

    private var autoSendingKey: String {
        mode == .historySyncSkip ? "history_sync_skip_sending" : "history_sync_auto_sending"
    }

    private var formattedPIN: String {
        let p = service.pin
        guard p.count == 6 else { return p }
        return "\(p.prefix(3)) \(p.dropFirst(3))"
    }

    private func prepare() async {
        do {
            let payload: Data
            let transferType: NearbyTransferService.TransferType
            switch mode {
            case .backup:
                payload = try await LocalBackupService.shared.buildTransferPayload(context: context)
                transferType = .backup
            case .historySync:
                let userId = KeychainManager.shared.loadUserID()
                payload = try await LocalBackupService.shared.buildTransferPayload(context: context, userId: userId)
                transferType = .historySync
            case .historySyncSkip:
                payload = Data()
                transferType = .historySyncSkipped
            }
            service.startSending(payload: payload, type: transferType, fixedPIN: autoPairingPIN)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
