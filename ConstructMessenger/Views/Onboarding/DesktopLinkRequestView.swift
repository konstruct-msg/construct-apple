//
//  DesktopLinkRequestView.swift
//  Construct Messenger / Construct Desktop
//
//  Shown on macOS during onboarding when the user taps "Link Existing Account".
//
//  The laptop generates a one-time "join request" QR that encodes its public key.
//  The user scans the QR with their iPhone running Construct.
//  The iPhone approves the request; the laptop polls for the resulting credentials.
//
//  Laptop always shows QR — phone always scans. No webcam. No copy-paste.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

#if !os(iOS)
struct DesktopLinkRequestView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var vm = DeviceLinkViewModel()
    @State private var showError = false

    var body: some View {
        NavigationStack {
            content
                .padding(32)
                .navigationTitle(LocalizedStringKey("device_link_request_title"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LocalizedStringKey("cancel")) {
                            vm.cancelPolling()
                            dismiss()
                        }
                    }
                }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 540)
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
        .onChange(of: vm.linkCompleted) { _, completed in
            guard completed else { return }
            let userId = KeychainManager.shared.loadUserID() ?? ""
            authViewModel.finalizeDeviceRegistration(userId: userId, username: nil)
            dismiss()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isGenerating {
            ProgressView()
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if let qrURL = vm.joinRequestQRContent {
            qrPanel(url: qrURL)

        } else if vm.errorMessage == nil {
            ProgressView()
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {
            // Error shown via alert — show a retry button as fallback
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Button(LocalizedStringKey("device_link_refresh")) {
                    vm.errorMessage = nil
                    Task { await vm.generateJoinRequestQR() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - QR panel

    private func qrPanel(url: String) -> some View {
        VStack(spacing: 28) {
            // Header
            VStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)

                Text(LocalizedStringKey("device_link_request_instruction"))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(LocalizedStringKey("device_link_request_steps"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // QR
            if let image = generateQRCode(from: url) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            }

            // Waiting indicator
            HStack(spacing: 8) {
                if vm.isWaitingForApproval {
                    ProgressView()
                        .scaleEffect(0.75)
                }
                Text(LocalizedStringKey(
                    vm.isWaitingForApproval
                        ? "device_link_waiting_approval"
                        : "device_link_scan_on_phone"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - QR generation

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
#endif
