//
//  VeilBootstrapScanView.swift
//  Construct Messenger
//
//  The "can't connect?" door. A fresh install in a blocked region cannot reach
//  registration, so it cannot reach Settings either — which is where the config
//  scanner has lived until now. This is the same import, hung off onboarding.
//
//  Deliberately secondary: a text button under the primary actions, never a peer
//  of "Create identity". Someone who can reach clearnet should never find it.
//  See decisions/user-vouched-veil-bootstrap.md §"Default-off in uncensored networks".
//

import SwiftUI

struct VeilBootstrapScanView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showingScanner = false
    @State private var showingPaste = false
    @State private var pasteText = ""
    @State private var message: String?
    @State private var isError = false
    @State private var isConfigured = false

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("veil_bootstrap_title", comment: ""),
                showBack: true,
                isModal: true,
                backAction: { dismiss() }
            )

            ScrollView {
                VStack(spacing: CTLayout.sectionGap) {
                    Text(NSLocalizedString("veil_bootstrap_intro", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, CTLayout.sectionGap)
                        .padding(.top, CTLayout.sectionGap)

                    if isConfigured {
                        configuredCard
                    } else {
                        #if os(iOS)
                        actionCard(
                            icon: "qrcode.viewfinder",
                            titleKey: "veil_config_scan",
                            subtitleKey: "veil_bootstrap_scan_subtitle"
                        ) { showingScanner = true }
                        #endif

                        actionCard(
                            icon: "doc.on.clipboard",
                            titleKey: "veil_config_paste",
                            subtitleKey: "veil_bootstrap_paste_subtitle"
                        ) { showingPaste = true }
                    }

                    if let message {
                        Text(message)
                            .font(CTFont.regular(12))
                            .foregroundColor(isError ? Color.CT.danger : Color.CT.accentDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, CTLayout.sectionGap)
                    }
                }
                .padding(.horizontal, CTLayout.edgePad)
                .padding(.bottom, CTLayout.sectionGap)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            QRScannerView { code in
                showingScanner = false
                redeem(code)
            }
        }
        #endif
        .alert(NSLocalizedString("veil_config_paste", comment: ""), isPresented: $showingPaste) {
            TextField(NSLocalizedString("veil_config_paste", comment: ""), text: $pasteText)
            Button(NSLocalizedString("veil_config_import", comment: "")) { redeem(pasteText) }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        }
    }

    /// Success copy is status-only. The import returns the relay address and this
    /// screen never renders it: the person reading it is on the device that just
    /// learned a front, and a screenshot of a hostname outlives the 45-minute code.
    private var configuredCard: some View {
        VStack(spacing: CTLayout.chromeGap) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.CT.accent)
            Text(NSLocalizedString("veil_bootstrap_ok", comment: ""))
                .font(CTFont.bold(13))
                .foregroundStyle(Color.CT.text)
                .multilineTextAlignment(.center)
            Text(NSLocalizedString("veil_bootstrap_ok_hint", comment: ""))
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.center)
            CTButton(label: NSLocalizedString("done", comment: "").uppercased()) { dismiss() }
                .padding(.top, 4)
        }
        .padding(.horizontal, CTLayout.edgePad)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Color.CT.bgMsg)
        .clipShape(CTShape.card())
        .overlay(CTShape.card().stroke(Color.CT.noise, lineWidth: 0.5))
    }

    private func actionCard(
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

    private func redeem(_ text: String) {
        pasteText = ""
        switch VeilVoucherRedemption.redeem(text) {
        case .success:
            isError = false
            isConfigured = true
            message = nil
        case .failure(let error):
            isError = true
            isConfigured = false
            message = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview {
    VeilBootstrapScanView()
}
#endif
