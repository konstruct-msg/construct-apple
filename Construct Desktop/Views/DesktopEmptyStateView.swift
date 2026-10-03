//
//  DesktopEmptyStateView.swift
//  Construct Desktop
//
//  The detail pane with no chat open. It used to be a spec sheet of the protocol stack; what a
//  person needs here is the next step: set up the recovery phrase (contacts wait on it) or add
//  someone.
//

import SwiftUI

struct DesktopEmptyStateView: View {
    /// Whether this device knows the account's address (`AccountAddress.own() != nil`). Without it
    /// no invite can be made or redeemed, so the phrase comes first.
    let hasAddress: Bool
    let onAddContact: () -> Void
    let onSetUpRecovery: () -> Void

    private static let contentWidth: CGFloat = 380
    private static let iconSize: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: CTLayout.sectionGap) {
                Image(systemName: hasAddress ? "bubble.left.and.bubble.right" : "key.horizontal")
                    .font(CTFont.ui(Self.iconSize, weight: .light))
                    .foregroundStyle(Color.CT.textDim)
                    .accessibilityHidden(true)

                VStack(spacing: CTLayout.chromeGap) {
                    Text(LocalizedStringKey(hasAddress ? "select_chat" : "recovery_gate_title"))
                        .font(CTFont.headline)
                        .foregroundStyle(Color.CT.text)
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey(hasAddress ? "select_chat_description" : "recovery_intro_body"))
                        .font(CTFont.secondary)
                        .foregroundStyle(Color.CT.textDim)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: CTLayout.chromeGap) {
                    if !hasAddress {
                        Button(action: onSetUpRecovery) {
                            Label(LocalizedStringKey("recovery_gate_setup_action"), systemImage: "key.horizontal")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(action: onAddContact) {
                        Label(LocalizedStringKey("add_contact_menu"), systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: Self.contentWidth)
            .padding(.horizontal, CTLayout.edgePad)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ctBackground()
    }
}

#Preview("No address") {
    DesktopEmptyStateView(hasAddress: false, onAddContact: {}, onSetUpRecovery: {})
        .frame(width: 640, height: 520)
}

#Preview("Ready") {
    DesktopEmptyStateView(hasAddress: true, onAddContact: {}, onSetUpRecovery: {})
        .frame(width: 640, height: 520)
}
