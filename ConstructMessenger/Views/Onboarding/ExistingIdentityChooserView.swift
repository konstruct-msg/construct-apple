//
//  ExistingIdentityChooserView.swift
//  Construct Messenger
//
//  Secondary onboarding branch: user already has an identity.
//  Equal-weight choices — restore (recovery phrase) OR link (another device).
//  No preselection; both cards share the same visual treatment.
//

import SwiftUI

struct ExistingIdentityChooserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountRecoveryViewModel.self) private var recoveryVM

    @State private var showingRecovery = false
    @State private var showingDeviceLink = false

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("onboarding_existing_title", comment: ""),
                showBack: true,
                isModal: true,
                backAction: { dismiss() }
            )

            ScrollView {
                VStack(spacing: CTLayout.sectionGap) {
                    Text(NSLocalizedString("onboarding_existing_intro", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, CTLayout.sectionGap)
                        .padding(.top, CTLayout.sectionGap)

                    choiceCard(
                        icon: "key.fill",
                        titleKey: "onboarding_restore_title",
                        subtitleKey: "onboarding_restore_subtitle"
                    ) {
                        showingRecovery = true
                    }

                    choiceCard(
                        icon: "link",
                        titleKey: "onboarding_link_title",
                        subtitleKey: "onboarding_link_subtitle"
                    ) {
                        showingDeviceLink = true
                    }
                }
                .padding(.horizontal, CTLayout.edgePad)
                .padding(.bottom, CTLayout.sectionGap)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .sheet(isPresented: $showingRecovery) {
            RecoveryEntryView()
                .environment(recoveryVM)
        }
        .sheet(isPresented: $showingDeviceLink) {
            #if os(iOS)
            DeviceLinkMethodView()
            #else
            DesktopLinkRequestView()
            #endif
        }
    }

    private func choiceCard(
        icon: String,
        titleKey: String,
        subtitleKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CTLayout.chromeGap) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.CT.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString(titleKey, comment: "").uppercased())
                        .font(CTFont.bold(13))
                        .foregroundStyle(Color.CT.text)
                        .tracking(1)
                    Text(NSLocalizedString(subtitleKey, comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.CT.textDim)
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, 16)
            .background(Color.CT.bgMsg)
            .clipShape(CTShape.card())
            .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    ExistingIdentityChooserView()
        .environment(AccountRecoveryViewModel())
}
#endif
