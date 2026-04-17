//
//  ReceiveBackupNearbyView.swift
//  Construct Messenger
//
//  Receives a backup payload from a nearby device over P2P WiFi.
//  User enters the 6-digit PIN displayed on the sender device.
//

import SwiftUI

struct ReceiveBackupNearbyView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var service = NearbyTransferService()
    @State private var pinInput = ""
    @State private var showRestartAlert = false
    @State private var isStaging = false
    @State private var stagingError: String?
    @State private var showError = false

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("transfer_receive_title", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                )
                content
            }
        }
        .onDisappear { service.cancel() }
        .alert(NSLocalizedString("backup_restore_required_title", comment: ""), isPresented: $showRestartAlert) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) { dismiss() }
        } message: {
            Text(NSLocalizedString("backup_restore_required_message", comment: ""))
        }
        .alert(NSLocalizedString("transfer_error_title", comment: ""), isPresented: $showError) {
            Button(NSLocalizedString("ok", comment: ""), role: .cancel) {}
        } message: {
            Text(stagingError ?? "")
        }
        .onChange(of: service.transferState) { _, newState in
            if case .complete = newState { handleReceiveComplete() }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch service.transferState {
                case .idle:
                    pinEntryView
                case .browsing:
                    statusView(
                        symbol: "[?]",
                        label: NSLocalizedString("transfer_searching", comment: "")
                    )
                case .handshaking:
                    statusView(
                        symbol: "[↔]",
                        label: NSLocalizedString("transfer_connecting", comment: "")
                    )
                case .transferring:
                    transferringView
                case .complete:
                    if isStaging {
                        statusView(
                            symbol: "[…]",
                            label: NSLocalizedString("transfer_staging", comment: "")
                        )
                    } else {
                        completeView
                    }
                case .failed(let msg):
                    failedView(msg)
                default:
                    EmptyView()
                }
            }
            .padding(20)
        }
    }

    private var pinEntryView: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(NSLocalizedString("transfer_enter_pin_hint", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)

                TextField("000000", text: $pinInput)
                    .numberPadKeyboard()
                    .font(CTFont.bold(32))
                    .tracking(8)
                    .foregroundColor(Color.CT.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .overlay(
                        Rectangle()
                            .stroke(Color.CT.noise, lineWidth: 1)
                    )
                    .onChange(of: pinInput) { _, v in
                        if v.count > 6 { pinInput = String(v.prefix(6)) }
                    }
            }

            Button {
                let raw = pinInput.filter(\.isNumber)
                guard raw.count == 6 else { return }
                service.startReceiving(pin: raw)
            } label: {
                Text(NSLocalizedString("transfer_connect", comment: "").uppercased())
                    .font(CTFont.bold(13))
                    .tracking(3)
                    .foregroundColor(Color.CT.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        pinInput.filter(\.isNumber).count == 6
                        ? Color.CT.accent
                        : Color.CT.noise
                    )
            }
            .disabled(pinInput.filter(\.isNumber).count != 6)
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
            Text(CTSymbol.forward)
                .font(CTFont.bold(32))
                .foregroundColor(Color.CT.accent)
            Text(NSLocalizedString("transfer_complete", comment: ""))
                .font(CTFont.bold(15))
                .foregroundColor(Color.CT.text)
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
            Text("[!]")
                .font(CTFont.bold(28))
                .foregroundColor(Color.CT.danger)
            Text(message)
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.danger)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("try_again", comment: "")) {
                service.reset()
                pinInput = ""
            }
            .font(CTFont.regular(13))
            .foregroundColor(Color.CT.accent)
            .padding(.top, 8)
        }
        .padding(.top, 40)
    }

    // MARK: - Logic

    private func handleReceiveComplete() {
        guard let payload = service.receivedPayload else { return }
        isStaging = true
        Task {
            do {
                try LocalBackupService.shared.stageTransferPayload(payload)
                service.receivedPayload = nil
                isStaging = false
                showRestartAlert = true
            } catch {
                service.receivedPayload = nil
                isStaging = false
                stagingError = error.localizedDescription
                showError = true
            }
        }
    }
}
