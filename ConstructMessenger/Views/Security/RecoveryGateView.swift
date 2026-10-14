//
//  RecoveryGateView.swift
//  Construct Messenger
//
//  Contacts need the account's address, and the address is the recovery key. A device that does
//  not know it cannot mint an invite (nothing to name) or redeem one safely (the server would be
//  the only source). This is where the user is told why, and sent to the one step that fixes it:
//  set up the recovery phrase, or — when the account already has one — enter it on this device.
//
//  decisions/invite-carries-the-account-address.md
//

import SwiftUI

/// Shows `content` once this device knows the account's address, the gate until then.
///
/// The address is checked against the server's fingerprint when the gate opens
/// (`AccountAddress.confirmedOwn`): an invite names it, so a stale one would send every
/// redeemer's messages to another account.
///
/// Wraps the surfaces that make or take a contact invite — the own QR and the contact scanners —
/// and nothing else: the same scanner links devices and imports VEIL configs, which need no
/// address.
struct RecoveryGated<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var ready = AccountAddress.own() != nil

    var body: some View {
        Group {
            if ready {
                content()
            } else {
                // In place of a sheet's content, so the gate brings the stack its bar needs.
                NavigationStack {
                    RecoveryGateView(reason: .contacts) { ready = true }
                }
            }
        }
        // Once per opening, not per invite: the QR is re-minted every few seconds. A key the
        // server says is another account's is deleted here and the gate closes; an unreachable
        // server leaves the stored one (an invite minted offline is unchecked, as before).
        .task {
            _ = await AccountAddress.confirmedOwn()
            ready = AccountAddress.own() != nil
        }
    }
}

struct RecoveryGateView: View {
    enum Reason {
        /// Right after registration, once. The user may postpone.
        case afterRegistration
        /// The user reached for an invite. Nothing else on the screen until it is done.
        case contacts
    }

    let reason: Reason
    /// Called once this device knows the account's address.
    var onReady: () -> Void = {}

    @Environment(AccountRecoveryViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var showingSetup = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: CTLayout.sectionGap) {
                    Image(systemName: "key.fill")
                        .font(CTFont.title)
                        .foregroundStyle(Color.CT.accent)
                        .accessibilityHidden(true)

                    Text(NSLocalizedString("recovery_gate_title", comment: ""))
                        .font(CTFont.title)
                        .foregroundColor(Color.CT.text)

                    Text(NSLocalizedString("recovery_gate_why", comment: ""))
                        .font(CTFont.body)
                        .foregroundColor(Color.CT.textDim)
                        .fixedSize(horizontal: false, vertical: true)

                    if !vm.statusLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if vm.isSetup {
                        confirmSection
                    } else {
                        setupSection
                    }
                }
                .padding(CTLayout.edgePad)
            }
        }
        .ctBackground()
        .screenTitle(NSLocalizedString("recovery_gate_nav_title", comment: ""))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString(
                    reason == .afterRegistration ? "recovery_gate_later" : "cancel",
                    comment: ""
                )) {
                    vm.resetConfirm()
                    dismiss()
                }
                .barItem()
            }
        }
        .task { await vm.loadStatus() }
        .sheet(isPresented: $showingSetup, onDismiss: checkReady) {
            RecoverySetupView().sheetNavigation(closes: false)
        }
        .onChange(of: vm.confirmStep) { _, step in
            if step == .done { checkReady() }
        }
    }

    // MARK: - Sections

    /// The account has no recovery key yet: make one.
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: CTLayout.sectionGap) {
            Text(NSLocalizedString("recovery_gate_setup_note", comment: ""))
                .font(CTFont.secondary)
                .foregroundColor(Color.CT.textDim)
                .fixedSize(horizontal: false, vertical: true)
            CTButton(label: NSLocalizedString("recovery_gate_setup_action", comment: "")) {
                showingSetup = true
            }
        }
    }

    /// The account has one, this device has not seen it: enter the phrase.
    private var confirmSection: some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: CTLayout.sectionGap) {
            Text(NSLocalizedString("recovery_gate_confirm_note", comment: ""))
                .font(CTFont.secondary)
                .foregroundColor(Color.CT.textDim)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                NSLocalizedString("recovery_confirm_placeholder", comment: ""),
                text: $vm.confirmPhrase,
                axis: .vertical
            )
            .lineLimit(3...6)
            .font(CTFont.mono(15))
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .padding(CTLayout.edgePad)
            .background(Color.CT.bgMsg)
            .clipShape(CTShape.card())
            .accessibilityLabel(NSLocalizedString("recovery_confirm_placeholder", comment: ""))

            if case .failed(let message) = vm.confirmStep {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(CTFont.secondary)
                    .foregroundColor(Color.CT.danger)
            }

            if vm.confirmStep == .checking {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                CTButton(
                    label: NSLocalizedString("recovery_confirm_action", comment: ""),
                    isEnabled: !vm.confirmPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task { await vm.submitConfirm() }
                }
            }
        }
    }

    // MARK: - Actions

    private func checkReady() {
        Task { await vm.refreshStatus() }
        guard AccountAddress.own() != nil else { return }
        vm.resetConfirm()
        onReady()
        if reason == .afterRegistration { dismiss() }
    }
}
