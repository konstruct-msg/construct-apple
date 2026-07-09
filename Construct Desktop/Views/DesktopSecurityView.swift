//
//  DesktopSecurityView.swift
//  Construct Desktop
//

import SwiftUI

struct DesktopSecurityView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM

    @State private var showingRecoverySetup = false

    var body: some View {
        @Bindable var securityViewModel = securityViewModel
        VStack(spacing: 0) {

            // MARK: - App Lock
            CTSettingsSectionHeader(title: NSLocalizedString("security", comment: ""))

            if securityViewModel.isBiometricAvailable {
                HStack(spacing: 10) {
                    Image(systemName: "faceid")
                        .foregroundStyle(securityViewModel.isBiometricEnabled ? Color.CT.accent : Color.CT.textDim)
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

                if securityViewModel.isBiometricEnabled {
                    CTSep(style: .thin)

                    HStack(spacing: 10) {
                        Text(NSLocalizedString("lock_delay", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.text)
                        Spacer()
                        Picker("", selection: $securityViewModel.lockDelay) {
                            ForEach(LockDelay.allCases) { delay in
                                Text(delay.localizedTitle).tag(delay)
                            }
                        }
                        .labelsHidden()
                        .font(CTFont.regular(12))
                        .frame(maxWidth: 140)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)

                    CTSep(style: .thin)

                    Button {
                        securityViewModel.lockIfNeeded()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                            Text(NSLocalizedString("lock_now", comment: ""))
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.CT.textDim)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text(NSLocalizedString("biometric_unavailable", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }

            CTSep(style: .thick)

            // MARK: - Account Recovery
            CTSettingsSectionHeader(title: NSLocalizedString("account_recovery_seed", comment: ""))

            Button { showingRecoverySetup = true } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.CT.textDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(LocalizedStringKey("account_recovery_seed_hint"))
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 12)

            Spacer()
        }
        .onAppear {
            securityViewModel.refreshBiometricAvailability()
            Task { await recoveryVM.refreshStatus() }
        }
        .sheet(isPresented: $showingRecoverySetup) {
            RecoverySetupView()
                .environment(recoveryVM)
                .frame(minWidth: 480, minHeight: 520)
                .onDisappear {
                    Task { await recoveryVM.refreshStatus() }
                }
        }
    }
}