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
    @Environment(\.dismiss) private var dismiss

    @State private var showingPinSetup = false
    @State private var showingDisablePinSheet = false
    @State private var showingRecoverySetup = false
    @State private var showingDuressPinSetup = false
    @State private var showingDisableDuressAlert = false
    @State private var lockdown = LockdownManager.shared

    var body: some View {
        @Bindable var securityViewModel = securityViewModel
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("security", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            ScrollView {
            VStack(spacing: 20) {

                // MARK: - PIN Code section
                ConstructSection(header: NSLocalizedString("PIN_CODE", comment: "")) {
                    ConstructButtonRow(
                        icon: "[lock]",
                        title: securityViewModel.isPinEnabled
                            ? LocalizedStringKey("change_pin_code")
                            : LocalizedStringKey("enable_pin_code"),
                        iconColor: Color.CT.textDim
                    ) {
                        showingPinSetup = true
                    }

                    if securityViewModel.isPinEnabled {
                        ConstructRowDivider(indent: 52)

                        HStack(spacing: 14) {
                            CTRowIcon(CTSymbol.biometric,
                                      color: securityViewModel.isBiometricEnabled ? Color.CT.accent : Color.CT.textDim)
                            Text(String(format: NSLocalizedString("use_biometric", comment: ""), securityViewModel.biometricDisplayName))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Toggle("", isOn: $securityViewModel.isBiometricEnabled)
                                .labelsHidden()
                                .tint(Color.CT.accent)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .disabled(!securityViewModel.isBiometricAvailable)

                        ConstructRowDivider(indent: 52)

                        ConstructActionRow(
                            icon: "[x]",
                            title: LocalizedStringKey("disable_pin_code"),
                            role: .destructive
                        ) {
                            showingDisablePinSheet = true
                        }
                    }
                }

                // MARK: - Account Recovery section
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("ACCOUNT_RECOVERY", comment: "")) {
                        Button { showingRecoverySetup = true } label: {
                            HStack(spacing: 14) {
                                CTRowIcon(recoveryVM.isSetup ? CTSymbol.ok : CTSymbol.key,
                                          color: recoveryVM.isSetup ? Color.CT.accent : Color.CT.textDim)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LocalizedStringKey("account_recovery_seed"))
                                        .font(CTFont.bold(16))
                                        .foregroundStyle(Color.CT.text)
                                    if recoveryVM.isSetup, let fp = recoveryVM.fingerprint {
                                        Text(fp)
                                            .font(CTFont.regular(11))
                                            .foregroundStyle(Color.CT.textDim)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    } else if recoveryVM.statusLoaded && !recoveryVM.isSetup {
                                        Text(NSLocalizedString("recovery_not_configured", comment: ""))
                                            .font(CTFont.regular(11))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Text("[→]")
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Text(LocalizedStringKey("account_recovery_seed_hint"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }

                // MARK: - Duress PIN section
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("DURESS_PIN", comment: "")) {
                        if securityViewModel.isDuresspinEnabled {
                            ConstructButtonRow(
                                icon: "[⚡]",
                                title: LocalizedStringKey("duress_pin_change"),
                                iconColor: Color.CT.danger
                            ) {
                                showingDuressPinSetup = true
                            }
                            ConstructRowDivider(indent: 52)
                            ConstructActionRow(
                                icon: "[x]",
                                title: LocalizedStringKey("disable_duress_pin"),
                                role: .destructive
                            ) {
                                showingDisableDuressAlert = true
                            }
                        } else {
                            ConstructButtonRow(
                                icon: "[⚡]",
                                title: LocalizedStringKey("enable_duress_pin"),
                                iconColor: securityViewModel.isPinEnabled ? Color.CT.textDim : Color.CT.textDim.opacity(0.4)
                            ) {
                                showingDuressPinSetup = true
                            }
                            .disabled(!securityViewModel.isPinEnabled)
                            .opacity(securityViewModel.isPinEnabled ? 1.0 : 0.5)
                        }
                    }
                    Text(LocalizedStringKey(securityViewModel.isPinEnabled ? "duress_pin_hint" : "duress_pin_requires_main_pin"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }

                // MARK: - Lockdown mode section
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("LOCKDOWN", comment: "")) {
                        HStack(spacing: 14) {
                            CTRowIcon(lockdown.isActive ? "[🔒]" : CTSymbol.lock,
                                      color: lockdown.isActive ? .orange : Color.CT.textDim)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(LocalizedStringKey("lockdown_mode"))
                                    .font(CTFont.bold(16))
                                    .foregroundStyle(Color.CT.text)
                                if lockdown.isActive, let since = lockdown.activatedAt {
                                    Text(String(format: NSLocalizedString("lockdown_active_since", comment: ""),
                                                since.formatted(date: .abbreviated, time: .shortened)))
                                        .font(CTFont.regular(11))
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { lockdown.isActive },
                                set: { enabled in
                                    if enabled {
                                        let approvedIds = fetchCurrentContactIds()
                                        lockdown.enable(approvedIds: approvedIds)
                                    } else {
                                        lockdown.disable()
                                    }
                                }
                            ))
                            .labelsHidden()
                            .tint(.orange)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    Text(LocalizedStringKey("lockdown_mode_hint"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 20)
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
        .background(Color.CT.bg.ignoresSafeArea())
    }

    // MARK: - Helpers

    /// Fetch IDs of all current chat partners from Core Data (snapshot for lockdown).
    private func fetchCurrentContactIds() -> Set<String> {
        let req = Chat.fetchRequest()
        let chats = (try? viewContext.fetch(req)) ?? []
        return Set(chats.compactMap { $0.otherUser?.id })
    }
}

#if DEBUG
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    return NavigationStack {
        SecurityView()
            .environment(\.managedObjectContext, context)
            .environment(SecurityViewModel())
            .environment(AccountRecoveryViewModel())
            .environment(AuthViewModel(context: context))
    }
    .preferredColorScheme(.dark)
}
#endif
