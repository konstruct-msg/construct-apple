//
//  SecurityView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 06.02.2026.
//

import SwiftUI

struct SecurityView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM
    @Environment(AuthViewModel.self) private var authVM

    @State private var showingPinSetup = false
    @State private var showingDisablePinSheet = false
    @State private var showingRecoverySetup = false
    @State private var showingDuressPin = false
    
    var body: some View {
        @Bindable var securityViewModel = securityViewModel
        List {
            Section {
                Button {
                    showingPinSetup = true
                } label: {
                    Label {
                        Text(securityViewModel.isPinEnabled ? "change_pin_code" : "enable_pin_code")
                            .foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.gray)
                    }
                }
                
                if securityViewModel.isPinEnabled {
                    Toggle(isOn: $securityViewModel.isBiometricEnabled) {
                        Label {
                            Text(String(format: NSLocalizedString("use_biometric", comment: ""), securityViewModel.biometricDisplayName))
                        } icon: {
                            Image(systemName: securityViewModel.biometricIconName)
                                .foregroundColor(Color.blue)
                        }
                    }
                    .disabled(!securityViewModel.isBiometricAvailable)
                    
                    Button(role: .destructive) {
                        showingDisablePinSheet = true
                    } label: {
                        Label {
                            Text("disable_pin_code")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "lock.slash.fill")
                                .foregroundColor(.red)
                        }
                    }
                }
            }

            Section {
                Button {
                    showingRecoverySetup = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("account_recovery_seed")
                                .foregroundColor(.primary)
                            if recoveryVM.isSetup, let fp = recoveryVM.fingerprint {
                                Text(fp)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else if recoveryVM.statusLoaded && !recoveryVM.isSetup {
                                Text(NSLocalizedString("recovery_not_configured", comment: ""))
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    } icon: {
                        Image(systemName: recoveryVM.isSetup ? "checkmark.shield.fill" : "key.fill")
                            .foregroundColor(recoveryVM.isSetup ? .green : .gray)
                    }
                }
            } footer: {
                Text("account_recovery_seed_hint")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button {
                    showingDuressPin = true
                } label: {
                    Label {
                        Text("duress_pin")
                            .foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "bolt.shield.fill")
                            .foregroundColor(.gray)
                    }
                }
            } footer: {
                Text("duress_pin_hint")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showingPinSetup) {
            PinSetupView(isChanging: securityViewModel.isPinEnabled)
                .environment(securityViewModel)
        }
        .sheet(isPresented: $showingDisablePinSheet) {
            PinDisableView()
                .environment(securityViewModel)
        }
        .sheet(isPresented: $showingRecoverySetup) {
            RecoverySetupView()
                .environment(recoveryVM)
                .environment(authVM)
                .onDisappear {
                    Task { await recoveryVM.refreshStatus() }
                }
        }
        .alert("duress_pin", isPresented: $showingDuressPin) {
            Button("ok", role: .cancel) { }
        } message: {
            Text("duress_pin_coming_soon")
        }
        .task { await recoveryVM.loadStatus() }
    }
}
