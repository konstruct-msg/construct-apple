//
//  DeviceLinkShowQRView.swift
//  Construct Messenger
//
//  New-device flow (iOS): this device SHOWS a "link-to-me" QR that an already
//  signed-in device scans and approves. The mirror of DeviceLinkScanView.
//
//  Used for account transfer old → new: the new phone/iPad shows this code,
//  the old device (Settings → Devices → scan) approves it.
//
//  Backend is shared with DesktopLinkRequestView — DeviceLinkViewModel
//  .generateJoinRequestQR() submits the request and polls for approval.
//

import SwiftUI

#if os(iOS)
struct DeviceLinkShowQRView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var vm = DeviceLinkViewModel()
    @State private var showError = false
    @State private var showReceiveHistorySync = false
    @State private var receiveHistorySyncPIN: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("device_link_request_title", comment: ""),
                    showBack: true,
                    backAction: { vm.cancelPolling(); dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                Rectangle().fill(Color.CT.noise).frame(height: 1)

                content
            }
            .background(Color.CT.bg.ignoresSafeArea())
        }
        .task { await vm.generateJoinRequestQR() }
        .onDisappear { vm.cancelPolling() }
        .alert(vm.errorMessage ?? "", isPresented: $showError) {
            Button(LocalizedStringKey("ok"), role: .cancel) { vm.errorMessage = nil }
            Button(LocalizedStringKey("device_link_refresh")) {
                vm.errorMessage = nil
                Task { await vm.generateJoinRequestQR() }
            }
        }
        .onChange(of: vm.errorMessage) { _, msg in showError = msg != nil }
        // Link handshake completed — this (new) device pulls credentials, then
        // offers to receive message history, mirroring DeviceLinkScanView.
        .onChange(of: vm.linkOutcome) { _, outcome in
            guard let outcome else { return }
            Task {
                await authViewModel.completeDeviceLink(outcome)
                receiveHistorySyncPIN = HistorySyncPairing.pin(
                    pendingDeviceId: outcome.deviceId,
                    userId: outcome.userId
                )
                showReceiveHistorySync = true
            }
        }
        .fullScreenCover(isPresented: $showReceiveHistorySync) {
            ReceiveBackupNearbyView(mode: .historySync, autoPairingPIN: receiveHistorySyncPIN)
                .onDisappear {
                    authViewModel.clearDeviceLinkPhase()
                    dismiss()
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let qrURL = vm.joinRequestQRContent {
            qrPanel(url: qrURL)
        } else {
            ProgressView()
                .tint(Color.CT.textDim)
                .scaleEffect(1.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func qrPanel(url: String) -> some View {
        ScrollView {
            VStack(spacing: CTLayout.sectionGap) {
                HStack(spacing: 6) {
                    Text(">")
                        .font(CTFont.bold(11))
                        .foregroundColor(Color.CT.accentDim)
                    Text(NSLocalizedString("device_link_section", comment: "").uppercased())
                        .font(CTFont.bold(11))
                        .foregroundColor(Color.CT.accentDim)
                        .tracking(2)
                    Spacer()
                }
                .padding(.horizontal, CTLayout.edgePad)
                .padding(.top, CTLayout.sectionGap)

                Text(NSLocalizedString("device_link_request_instruction", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CTLayout.sectionGap)

                if let image = QRCodeGenerator.generate(from: url) {
                    qrImageView(image)
                }

                HStack(spacing: 8) {
                    if vm.isWaitingForApproval {
                        ProgressView()
                            .tint(Color.CT.textDim)
                            .scaleEffect(0.8)
                    }
                    Text(LocalizedStringKey(
                        vm.isWaitingForApproval
                            ? "device_link_waiting_approval"
                            : "device_link_request_steps"
                    ))
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, CTLayout.sectionGap)
                .padding(.bottom, CTLayout.sectionGap)
            }
        }
    }

    @ViewBuilder
    private func qrImageView(_ image: PlatformImage) -> some View {
        Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(width: 240, height: 240)
            .padding(16)
            .background(Color.white)
            .clipShape(CTShape.card())
            .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 1))
    }
}
#endif
