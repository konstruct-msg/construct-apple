//
//  DesktopSecurityView.swift
//  Construct Desktop
//

import SwiftUI

struct DesktopSecurityView: View {
    @Environment(SecurityViewModel.self) private var securityViewModel

    var body: some View {
        @Bindable var securityViewModel = securityViewModel
        VStack(spacing: 0) {

            // MARK: - App Lock
            CTSettingsSectionHeader(title: NSLocalizedString("security", comment: ""))

            if securityViewModel.isBiometricAvailable {
                // Biometric lock toggle
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

                    // Lock delay picker
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

                    // Lock Now
                    Button {
                        securityViewModel.lockIfNeeded()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "lock.fill")
                            
                            Text(NSLocalizedString("lock_now", comment: ""))
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.textDim)
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

            Spacer()
        }
        .onAppear {
            securityViewModel.refreshBiometricAvailability()
        }
    }
}
