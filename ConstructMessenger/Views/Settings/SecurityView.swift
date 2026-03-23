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
    @Environment(\.managedObjectContext) private var viewContext

    @State private var showingPinSetup = false
    @State private var showingDisablePinSheet = false
    @State private var showingRecoverySetup = false
    @State private var showingDuressPinSetup = false
    @State private var showingDisableDuressAlert = false
    @State private var lockdown = LockdownManager.shared
    
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
                if securityViewModel.isDuresspinEnabled {
                    Button {
                        showingDuressPinSetup = true
                    } label: {
                        Label {
                            Text("duress_pin_change")
                                .foregroundColor(.primary)
                        } icon: {
                            Image(systemName: "bolt.shield.fill")
                                .foregroundColor(.red)
                        }
                    }

                    Button(role: .destructive) {
                        showingDisableDuressAlert = true
                    } label: {
                        Label {
                            Text("disable_duress_pin")
                                .foregroundColor(.red)
                        } icon: {
                            Image(systemName: "bolt.shield")
                                .foregroundColor(.red)
                        }
                    }
                } else {
                    Button {
                        showingDuressPinSetup = true
                    } label: {
                        Label {
                            Text("enable_duress_pin")
                                .foregroundColor(securityViewModel.isPinEnabled ? .primary : .secondary)
                        } icon: {
                            Image(systemName: "bolt.shield.fill")
                                .foregroundColor(securityViewModel.isPinEnabled ? .gray : .gray.opacity(0.4))
                        }
                    }
                    .disabled(!securityViewModel.isPinEnabled)
                }
            } footer: {
                Text(securityViewModel.isPinEnabled
                     ? "duress_pin_hint"
                     : "duress_pin_requires_main_pin")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // MARK: - Lockdown mode
            Section {
                Toggle(isOn: Binding(
                    get: { lockdown.isActive },
                    set: { enabled in
                        if enabled {
                            let approvedIds = fetchCurrentContactIds()
                            lockdown.enable(approvedIds: approvedIds)
                        } else {
                            lockdown.disable()
                        }
                    }
                )) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey("lockdown_mode"))
                                .foregroundColor(.primary)
                            if lockdown.isActive, let since = lockdown.activatedAt {
                                Text(String(format: NSLocalizedString("lockdown_active_since", comment: ""),
                                            since.formatted(date: .abbreviated, time: .shortened)))
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    } icon: {
                        Image(systemName: lockdown.isActive ? "lock.shield.fill" : "lock.shield")
                            .foregroundColor(lockdown.isActive ? .orange : .gray)
                    }
                }
                .tint(.orange)
            } footer: {
                Text(LocalizedStringKey("lockdown_mode_hint"))
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
        .sheet(isPresented: $showingDuressPinSetup) {
            DuressPinSetupView()
                .environment(securityViewModel)
        }
        .alert("disable_duress_pin", isPresented: $showingDisableDuressAlert) {
            Button("disable_duress_pin", role: .destructive) {
                securityViewModel.disableDuressPin()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("duress_pin_disable_warning")
        }
        .task { await recoveryVM.loadStatus() }
        .onAppear { securityViewModel.refreshPinState() }
    }

    // MARK: - Helpers

    /// Fetch IDs of all current chat partners from Core Data (snapshot for lockdown).
    private func fetchCurrentContactIds() -> Set<String> {
        let req = Chat.fetchRequest()
        let chats = (try? viewContext.fetch(req)) ?? []
        return Set(chats.compactMap { $0.otherUser?.id })
    }
}
