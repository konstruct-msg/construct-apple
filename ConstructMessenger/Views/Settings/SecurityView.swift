//
//  SecurityView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 06.02.2026.
//

import SwiftUI

struct SecurityView: View {
    @EnvironmentObject var securityViewModel: SecurityViewModel
    
    @State private var showingPinSetup = false
    @State private var showingDisablePinSheet = false
    @State private var showingSeedRecovery = false
    
    var body: some View {
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
                                .foregroundColor(Color.AppBrand.second)
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
                    showingSeedRecovery = true
                } label: {
                    Label {
                        Text("account_recovery_seed")
                            .foregroundColor(.primary)
                    } icon: {
                        Image(systemName: "key.fill")
                            .foregroundColor(.gray)
                    }
                }
            } footer: {
                Text("account_recovery_seed_hint")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showingPinSetup) {
            PinSetupView(isChanging: securityViewModel.isPinEnabled)
                .environmentObject(securityViewModel)
        }
        .sheet(isPresented: $showingDisablePinSheet) {
            PinDisableView()
                .environmentObject(securityViewModel)
        }
        .alert("account_recovery_seed", isPresented: $showingSeedRecovery) {
            Button("ok", role: .cancel) { }
        } message: {
            Text("account_recovery_seed_coming_soon")
        }
    }
}
