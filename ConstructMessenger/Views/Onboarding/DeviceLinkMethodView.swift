//
//  DeviceLinkMethodView.swift
//  Construct Messenger
//
//  iOS entry point for linking THIS device to an existing account (onboarding).
//  Offers both directions so account transfer old → new works either way:
//   • Scan a code — the other (signed-in) device shows a QR (Flow A).
//   • Show a code — the other device scans this one (Flow B / join request).
//
//  Both flows are full-screen experiences (camera / QR display), presented as
//  covers to avoid nested navigation chrome.
//

import SwiftUI

#if os(iOS)
struct DeviceLinkMethodView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var showScan = false
    @State private var showQR = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CTNavBar(
                    title: NSLocalizedString("link_method_title", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                Rectangle().fill(Color.CT.noise).frame(height: 1)

                ScrollView {
                    VStack(spacing: CTLayout.sectionGap) {
                        Text(NSLocalizedString("link_method_intro", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, CTLayout.sectionGap)
                            .padding(.top, CTLayout.sectionGap)

                        methodCard(
                            icon: "qrcode.viewfinder",
                            titleKey: "link_method_scan_title",
                            subtitleKey: "link_method_scan_subtitle"
                        ) { showScan = true }

                        methodCard(
                            icon: "qrcode",
                            titleKey: "link_method_show_title",
                            subtitleKey: "link_method_show_subtitle"
                        ) { showQR = true }
                    }
                    .padding(.horizontal, CTLayout.edgePad)
                    .padding(.bottom, CTLayout.sectionGap)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color.CT.bg.ignoresSafeArea())
        }
        .fullScreenCover(isPresented: $showScan) { DeviceLinkScanView() }
        .fullScreenCover(isPresented: $showQR) { DeviceLinkShowQRView() }
    }

    private func methodCard(
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
#endif
