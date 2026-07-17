//
//  KeysRecoveryView.swift
//  ConstructMessenger
//
//  Shown when the user is authenticated but device crypto keys couldn't be
//  loaded from Keychain (partial Keychain state, iOS Keychain bug, etc.).
//  Keys are NOT wiped until the user explicitly chooses "New Account".
//

import SwiftUI

struct KeysRecoveryView: View {
    /// Why the recovery screen is shown. Only the warning copy and the Retry action differ;
    /// seed-phrase recovery and "new account" are identical for both.
    enum Reason {
        /// Authenticated but device crypto keys couldn't be read from Keychain.
        case keysUnavailable
        /// Server rejected this device as unregistered (UNAUTHENTICATED / "device not found");
        /// keys are still present locally, so nothing is wiped until the user chooses.
        case deviceDeregistered
    }

    var reason: Reason = .keysUnavailable

    @Environment(AuthViewModel.self) private var auth
    @State private var recoveryVM = AccountRecoveryViewModel()
    @State private var showRecovery = false
    @State private var showWipeConfirm = false
    @State private var retryCount = 0

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                CTNavBar(title: NSLocalizedString("keys_recovery_title", comment: "")) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Warning block
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString(warningTitleKey, comment: ""))
                                .font(CTFont.bold(13))
                                .foregroundColor(Color.CT.danger)
                                .tracking(2)

                            Text(NSLocalizedString(warningBodyKey, comment: ""))
                                .font(CTFont.regular(13))
                                .foregroundColor(Color.CT.text)
                                .lineSpacing(4)
                        }
                        .padding(16)
                        .overlay(
                            Rectangle()
                                .stroke(Color.CT.danger, lineWidth: 1)
                        )

                        Rectangle().fill(Color.CT.noise).frame(height: 1)

                        // Option 1: Retry
                        CTSettingsSectionHeader(title: NSLocalizedString("keys_recovery_section_retry", comment: ""))
                        Text(NSLocalizedString(retryHintKey, comment: ""))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .padding(.horizontal, 20)
                        Button {
                            retryCount += 1
                            switch reason {
                            case .keysUnavailable:    auth.retryLoadingDeviceKeys()
                            case .deviceDeregistered: auth.retryDeviceAuthentication()
                            }
                        } label: {
                            CTSettingsRow(
                                label: NSLocalizedString("keys_recovery_retry_action", comment: ""),
                                value: retryCount > 0
                                    ? NSLocalizedString("keys_recovery_retry_failed", comment: "")
                                    : "",
                                valueColor: Color.CT.danger,
                                disclosure: retryCount == 0
                            )
                        }
                        .buttonStyle(.plain)

                        Rectangle().fill(Color.CT.noise).frame(height: 1)

                        // Option 2: Recover with seed
                        CTSettingsSectionHeader(title: NSLocalizedString("keys_recovery_section_seed", comment: ""))
                        Text(NSLocalizedString("keys_recovery_seed_hint", comment: ""))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .padding(.horizontal, 20)
                        Button {
                            showRecovery = true
                        } label: {
                            CTSettingsRow(
                                label: NSLocalizedString("keys_recovery_seed_action", comment: ""),
                                disclosure: true
                            )
                        }
                        .buttonStyle(.plain)

                        Rectangle().fill(Color.CT.noise).frame(height: 1)

                        // Option 3: New account
                        CTSettingsSectionHeader(
                            title: NSLocalizedString("keys_recovery_section_new", comment: ""),
                            color: Color.CT.danger
                        )
                        Text(NSLocalizedString("keys_recovery_new_hint", comment: ""))
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .padding(.horizontal, 20)
                        Button {
                            showWipeConfirm = true
                        } label: {
                            CTSettingsRow(
                                label: NSLocalizedString("keys_recovery_new_action", comment: ""),
                                isDestructive: true,
                                disclosure: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .sheet(isPresented: $showRecovery) {
            RecoveryEntryView()
                .environment(recoveryVM)
        }
        .alert(
            NSLocalizedString("keys_recovery_wipe_confirm_title", comment: ""),
            isPresented: $showWipeConfirm
        ) {
            Button(NSLocalizedString("keys_recovery_wipe_confirm_action", comment: ""), role: .destructive) {
                auth.wipeAndReregister()
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("keys_recovery_wipe_confirm_body", comment: ""))
        }
    }

    // MARK: - Reason-specific copy

    private var warningTitleKey: String {
        switch reason {
        case .keysUnavailable:    return "keys_recovery_warning_title"
        case .deviceDeregistered: return "device_deregistered_warning_title"
        }
    }

    private var warningBodyKey: String {
        switch reason {
        case .keysUnavailable:    return "keys_recovery_warning_body"
        case .deviceDeregistered: return "device_deregistered_warning_body"
        }
    }

    private var retryHintKey: String {
        switch reason {
        case .keysUnavailable:    return "keys_recovery_retry_hint"
        case .deviceDeregistered: return "device_deregistered_retry_hint"
        }
    }
}
