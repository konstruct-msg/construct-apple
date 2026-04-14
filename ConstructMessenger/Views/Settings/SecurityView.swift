//
//  SecurityView.swift
//  ConstructMessenger
//
//  Created by Maxim Eliseyev on 06.02.2026.
//

import SwiftUI

struct SecurityView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(SettingsViewModel.self) private var settingsViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM
    @Environment(AuthViewModel.self) private var authVM
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingPinSetup = false
    @State private var showingDisablePinSheet = false
    @State private var showingRecoverySetup = false
    @State private var showingDuressPinSetup = false
    @State private var showingDisableDuressAlert = false
    @State private var showingDiscoverableConfirm = false
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
            VStack(spacing: 0) {

                // MARK: - PIN Code
                CTSettingsSectionHeader(title: NSLocalizedString("pin_code", comment: ""))

                Button { showingPinSetup = true } label: {
                    HStack(spacing: 10) {
                        CTRowIcon(CTSymbol.lock)
                        Text(securityViewModel.isPinEnabled
                             ? LocalizedStringKey("change_pin_code")
                             : LocalizedStringKey("enable_pin_code"))
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.text)
                        Spacer()
                        Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if securityViewModel.isPinEnabled {
                    CTSep(style: .thin)
                    HStack(spacing: 10) {
                        CTRowIcon(CTSymbol.biometric,
                                  color: securityViewModel.isBiometricEnabled ? Color.CT.accent : Color.CT.textDim)
                        Text(String(format: NSLocalizedString("use_biometric", comment: ""),
                                    securityViewModel.biometricDisplayName))
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.text)
                        Spacer()
                        Toggle("", isOn: $securityViewModel.isBiometricEnabled)
                            .labelsHidden()
                            .tint(Color.CT.accent)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .disabled(!securityViewModel.isBiometricAvailable)

                    CTSep(style: .thin)
                    Button { showingDisablePinSheet = true } label: {
                        HStack(spacing: 10) {
                            CTRowIcon("[x]", color: Color.CT.danger)
                            Text(LocalizedStringKey("disable_pin_code"))
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.danger)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                CTSep()

                // MARK: - Account Recovery
                CTSettingsSectionHeader(title: NSLocalizedString("account_recovery", comment: ""))

                Button { showingRecoverySetup = true } label: {
                    HStack(spacing: 10) {
                        CTRowIcon(recoveryVM.isSetup ? CTSymbol.ok : CTSymbol.key,
                                  color: recoveryVM.isSetup ? Color.CT.accent : Color.CT.textDim)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey("account_recovery_seed"))
                                .font(CTFont.regular(13))
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
                        Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(LocalizedStringKey("account_recovery_seed_hint"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)

                CTSep()

                // MARK: - Duress PIN
                CTSettingsSectionHeader(title: NSLocalizedString("duress_pin", comment: ""))

                if securityViewModel.isDuresspinEnabled {
                    Button { showingDuressPinSetup = true } label: {
                        HStack(spacing: 10) {
                            CTRowIcon("[]", color: Color.CT.danger)
                            Text(LocalizedStringKey("duress_pin_change"))
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    CTSep(style: .thin)
                    Button { showingDisableDuressAlert = true } label: {
                        HStack(spacing: 10) {
                            CTRowIcon("[x]", color: Color.CT.danger)
                            Text(LocalizedStringKey("disable_duress_pin"))
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.danger)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { showingDuressPinSetup = true } label: {
                        HStack(spacing: 10) {
                            CTRowIcon("[]", color: securityViewModel.isPinEnabled
                                      ? Color.CT.textDim : Color.CT.textDim.opacity(0.4))
                            Text(LocalizedStringKey("enable_duress_pin"))
                                .font(CTFont.regular(13))
                                .foregroundStyle(securityViewModel.isPinEnabled
                                                 ? Color.CT.text : Color.CT.text.opacity(0.4))
                            Spacer()
                            Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!securityViewModel.isPinEnabled)
                }

                Text(LocalizedStringKey(securityViewModel.isPinEnabled ? "duress_pin_hint" : "duress_pin_requires_main_pin"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)

                CTSep()

                // MARK: - Lockdown
                CTSettingsSectionHeader(title: NSLocalizedString("lockdown_mode", comment: ""))

                HStack(spacing: 10) {
                    CTRowIcon(lockdown.isActive ? "[]" : CTSymbol.lock,
                              color: lockdown.isActive ? .orange : Color.CT.textDim)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey("lockdown_mode"))
                            .font(CTFont.regular(13))
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
                .padding(.horizontal, 12).padding(.vertical, 10)

                Text(LocalizedStringKey("lockdown_mode_hint"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)

                CTSep()

                // MARK: - Discovery
                CTSettingsSectionHeader(title: NSLocalizedString("discovery", comment: ""))

                let hasUsername = !authVM.currentUsername.isEmpty
                HStack(spacing: 10) {
                    CTRowIcon("[⊙]", color: settingsViewModel.isDiscoverable ? Color.CT.accent : Color.CT.textDim)
                    Text(LocalizedStringKey("searchable_toggle_title"))
                        .font(CTFont.regular(13))
                        .foregroundStyle(hasUsername ? Color.CT.text : Color.CT.textDim)
                    Spacer()
                    if settingsViewModel.isLoadingDiscoverable {
                        ProgressView()
                            .tint(Color.CT.accent)
                            .scaleEffect(0.8)
                    } else {
                        Toggle("", isOn: Binding(
                            get: { settingsViewModel.isDiscoverable },
                            set: { newValue in
                                if newValue {
                                    showingDiscoverableConfirm = true
                                } else {
                                    Task { await settingsViewModel.setDiscoverable(false) }
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(Color.CT.accent)
                        .disabled(!hasUsername)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                if !authVM.currentUsername.isEmpty {
                    Text(LocalizedStringKey("searchable_toggle_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
                } else {
                    Text(LocalizedStringKey("searchable_no_username_hint"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
                }

                CTSep()
            }
            .padding(.vertical, 8)
        }
        .alert("searchable_confirm_title", isPresented: $showingDiscoverableConfirm) {
            Button(LocalizedStringKey("searchable_confirm_action")) {
                Task { await settingsViewModel.setDiscoverable(true) }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("searchable_confirm_message"))
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
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
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
            .environment(SettingsViewModel())
    }
    .preferredColorScheme(.dark)
}
#endif
