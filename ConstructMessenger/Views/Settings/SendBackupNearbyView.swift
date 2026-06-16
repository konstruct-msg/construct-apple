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
    }

    var mode: Mode = .backup

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
                    title: NSLocalizedString(mode == .historySync ? "history_sync_send_title" : "transfer_send_title", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                )
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
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                switch service.transferState {
                case .idle, .preparing:
                    preparingView
                case .advertising:
                    advertisingView
                case .browsing, .handshaking:
                    statusView(
                        symbol: "[↔]",
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

    private func statusView(symbol: String, label: String) -> some View {
        VStack(spacing: 16) {
            Text(symbol)
                .font(CTFont.bold(28))
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

    private var formattedPIN: String {
        let p = service.pin
        guard p.count == 6 else { return p }
        return "\(p.prefix(3)) \(p.dropFirst(3))"
    }

    private func prepare() async {
        do {
            let userId = mode == .historySync ? KeychainManager.shared.loadUserID() : nil
            let payload = try await LocalBackupService.shared.buildTransferPayload(context: context, userId: userId)
            let transferType: NearbyTransferService.TransferType = mode == .historySync ? .historySync : .backup
            service.startSending(payload: payload, type: transferType)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
