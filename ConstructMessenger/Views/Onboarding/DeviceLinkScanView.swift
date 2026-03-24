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

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var vm = DeviceLinkViewModel()
    @State private var showError = false
    @State private var showApprovalSuccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView { scannedURL in
                    guard !vm.isLinking else { return }
                    Task { await vm.scanAndLink(scannedURL: scannedURL) }
                }
                .ignoresSafeArea()
                .navigationBarHidden(true)

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
        // MARK: Error
        .alert(vm.errorMessage ?? "", isPresented: $showError) {
            Button(LocalizedStringKey("ok"), role: .cancel) { vm.errorMessage = nil }
        }
        .onChange(of: vm.errorMessage) { _, msg in showError = msg != nil }
        // MARK: New device link completed (phone joined existing account)
        .onChange(of: vm.linkCompleted) { _, completed in
            guard completed else { return }
            let userId = KeychainManager.shared.loadUserID() ?? ""
            authViewModel.finalizeDeviceRegistration(userId: userId, username: nil)
            dismiss()
        }
        // MARK: Phone approved a laptop's join request
        .onChange(of: vm.approvalGranted) { _, granted in
            guard granted else { return }
            showApprovalSuccess = true
        }
        .alert(LocalizedStringKey("device_link_approved_title"), isPresented: $showApprovalSuccess) {
            Button(LocalizedStringKey("ok"), role: .cancel) { dismiss() }
        } message: {
            Text(LocalizedStringKey("device_link_approved_message"))
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
