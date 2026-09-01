//
//  DeviceLinkScanView.swift
//  Construct Messenger
//
//  Device B flow — phone scans QR shown on another device's screen.
//
//  Handles two QR types:
//   • konstruct://link?token=...       — existing device's invite token (confirmLink)
//   • konstruct://link-to-me?id=...   — desktop's join-request (approveJoinRequest)
//
//  Always iOS-only: the phone always scans, the laptop always shows.
//

import SwiftUI

#if os(iOS)
struct DeviceLinkScanView: View {

    private enum HistorySyncSenderSheet: Identifiable {
        case send
        case skip

        var id: String {
            switch self {
            case .send: return "send"
            case .skip: return "skip"
            }
        }

        var mode: SendBackupNearbyView.Mode {
            switch self {
            case .send: return .historySync
            case .skip: return .historySyncSkip
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var vm = DeviceLinkViewModel()
    @State private var showError = false
    @State private var showReceiveHistorySync = false
    @State private var showHistorySyncOffer = false
    @State private var activeHistorySyncSender: HistorySyncSenderSheet? = nil
    @State private var historySyncPIN: String? = nil
    /// Receiver-side auto PIN (derived from our own new device id) so history sync auto-connects.
    @State private var receiveHistorySyncPIN: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { scannedURL in
                    guard !vm.isLinking else { return }
                    Task { await vm.scanAndLink(scannedURL: scannedURL) }
                }
                .ignoresSafeArea()
                #if os(iOS)
                .navigationBarHidden(true)
                #endif

                if vm.isLinking {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.6)
                            .tint(.white)
                        Text(LocalizedStringKey("device_link_linking"))
                            .foregroundStyle(.white)
                            .font(.headline)
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("device_link_scan_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("cancel")) { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        // MARK: Confirmation — phone approves laptop's join request
        .confirmationDialog(
            approvalTitle,
            isPresented: Binding(
                get: { vm.pendingApproval != nil },
                set: { if !$0 { vm.pendingApproval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("device_link_approve")) {
                guard let info = vm.pendingApproval else { return }
                vm.pendingApproval = nil
                Task { await vm.approveJoinRequest(from: info.scannedURL) }
            }
            Button(LocalizedStringKey("cancel"), role: .cancel) {
                vm.pendingApproval = nil
            }
        } message: {
            Text(LocalizedStringKey("device_link_approve_message"))
        }
        // MARK: History-sync offer — phone (history owner) chooses to send after linking.
        // .alert (not confirmationDialog): two stacked confirmationDialogs on one view drop
        // buttons on iOS, and AGENTS.md prefers .alert — it reliably renders both choices.
        .alert(
            LocalizedStringKey("history_sync_send_offer_title"),
            isPresented: $showHistorySyncOffer
        ) {
            Button(LocalizedStringKey("history_sync_send_offer_yes")) {
                showHistorySyncOffer = false
                activeHistorySyncSender = .send
            }
            Button(LocalizedStringKey("history_sync_send_offer_skip"), role: .cancel) {
                showHistorySyncOffer = false
                if historySyncPIN != nil {
                    activeHistorySyncSender = .skip
                } else {
                    authViewModel.clearDeviceLinkPhase()
                    dismiss()
                }
            }
        } message: {
            Text(LocalizedStringKey("history_sync_send_offer_message"))
        }
        // MARK: Error
        .alert(vm.errorMessage ?? "", isPresented: $showError) {
            Button(LocalizedStringKey("ok"), role: .cancel) { vm.errorMessage = nil }
        }
        .onChange(of: vm.errorMessage) { _, msg in showError = msg != nil }
        // MARK: Link handshake completed — unified post-link bootstrap
        .onChange(of: vm.linkOutcome) { _, outcome in
            guard let outcome else { return }
            Task {
                await authViewModel.completeDeviceLink(outcome)
                guard DeviceLinkHistorySyncPolicy.isPostLinkEnabled else {
                    dismiss()
                    return
                }

                switch outcome.role {
                case .linkedNewDevice:
                    receiveHistorySyncPIN = HistorySyncPairing.pin(
                        pendingDeviceId: outcome.deviceId,
                        userId: outcome.userId
                    )
                    showReceiveHistorySync = true
                case .approvedJoinRequest:
                    // Device linked. Offer to sync history to the new device — the user with
                    // the message history decides; no codes, no steps beyond a yes/no.
                    if let pendingId = outcome.pendingDeviceId,
                       let userId = KeychainManager.shared.loadUserID() {
                        historySyncPIN = HistorySyncPairing.pin(pendingDeviceId: pendingId, userId: userId)
                        showHistorySyncOffer = true
                    } else {
                        dismiss()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showReceiveHistorySync) {
            ReceiveBackupNearbyView(mode: .historySync, autoPairingPIN: receiveHistorySyncPIN)
                .onDisappear {
                    authViewModel.clearDeviceLinkPhase()
                    dismiss()
                }
        }
        .sheet(item: $activeHistorySyncSender) { sheet in
            SendBackupNearbyView(mode: sheet.mode, autoPairingPIN: historySyncPIN)
                .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
                .onDisappear {
                    authViewModel.clearDeviceLinkPhase()
                    dismiss()
                }
        }
    }

    private var approvalTitle: String {
        if let name = vm.pendingApproval?.deviceName {
            let template = NSLocalizedString("device_link_approve_title", comment: "")
            return String(format: template, name)
        }
        return NSLocalizedString("device_link_approve_title_fallback", comment: "")
    }
}
#endif
