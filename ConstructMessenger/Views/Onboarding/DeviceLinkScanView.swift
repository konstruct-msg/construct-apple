//
//  DeviceLinkScanView.swift
//  Construct Messenger
//
//  Device B flow: new device scans the QR shown on Device A to link accounts.
//  Shown from OnboardingView when the user taps "Link Existing Account".
//

import SwiftUI

struct DeviceLinkScanView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var authViewModel

    @State private var vm = DeviceLinkViewModel()
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ZStack {
                // QR scanner fills the screen
                #if os(iOS)
                QRScannerView { scannedURL in
                    guard !vm.isLinking else { return }
                    Task { await vm.scanAndLink(scannedURL: scannedURL) }
                }
                .ignoresSafeArea()
                .navigationBarHidden(true)
                #else
                macOSLinkEntry
                #endif

                // Overlay while linking
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
        .alert(vm.errorMessage ?? "", isPresented: $showError) {
            Button(LocalizedStringKey("ok"), role: .cancel) { vm.errorMessage = nil }
        }
        .onChange(of: vm.errorMessage) { _, msg in
            showError = msg != nil
        }
        .onChange(of: vm.linkCompleted) { _, completed in
            guard completed else { return }
            // Credentials already saved to Keychain in DeviceLinkViewModel.
            // Update AuthViewModel so ContentView routes to the main app.
            let userId = KeychainManager.shared.loadUserID() ?? ""
            authViewModel.finalizeDeviceRegistration(userId: userId, username: nil)
            dismiss()
        }
    }

    // MARK: - macOS: manual token entry (no camera QR scanner)

    @State private var manualToken: String = ""

    private var macOSLinkEntry: some View {
        Form {
            Section {
                Text(LocalizedStringKey("device_link_macos_instructions"))
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField(LocalizedStringKey("device_link_token_placeholder"), text: $manualToken)
                    .autocorrectionDisabled()
                Button(LocalizedStringKey("device_link_confirm")) {
                    let token = manualToken.trimmingCharacters(in: .whitespaces)
                    guard !token.isEmpty else { return }
                    Task { await vm.confirmLink(token: token) }
                }
                .disabled(manualToken.trimmingCharacters(in: .whitespaces).isEmpty || vm.isLinking)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
        .padding()
    }
}
