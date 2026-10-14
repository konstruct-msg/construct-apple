//
//  ChatKeyChangeBannerView.swift
//  Construct Messenger
//
//  First-class trust event: a new device, a different address, or a failed KT proof.
//  Not a tiny nav badge — requires user attention.
//

import SwiftUI

/// Prominent banner for a contact's `ContactTrustAlert`.
///
/// Actions:
/// - **Verify** → open Safety Numbers (OOB compare), one per device of the contact
/// - **I've checked** → acknowledge; the banner goes until the next event
struct ChatKeyChangeBannerView: View {
    let alert: ContactTrustAlert?
    let contactName: String
    let onVerify: () -> Void
    let onAccept: () -> Void

    var body: some View {
        if let alert {
            VStack(alignment: .leading, spacing: CTLayout.chromeGap) {
                HStack(alignment: .top, spacing: CTLayout.chromeGap) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(CTFont.ui(18))
                        .foregroundStyle(Color.CT.danger)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString(alert.titleKey, comment: ""))
                            .font(CTFont.ui(12, weight: .bold))
                            .foregroundStyle(Color.CT.text)
                        Text(alert.subtitle(contactName: contactName))
                            .font(CTFont.caption)
                            .foregroundStyle(Color.CT.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: CTLayout.inlinePad) {
                    Button(action: onVerify) {
                        Text(NSLocalizedString("key_change_verify", comment: ""))
                            .font(CTFont.ui(12, weight: .bold))
                            .foregroundStyle(Color.CT.bg)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.CT.danger)
                            .clipShape(CTShape.control())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("key_change_verify", comment: ""))

                    Button(action: onAccept) {
                        Text(NSLocalizedString("security_notice_acknowledge", comment: ""))
                            .font(CTFont.secondary)
                            .foregroundStyle(Color.CT.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.CT.bgMsg)
                            .clipShape(CTShape.control())
                            .overlay(
                                CTShape.control()
                                    .strokeBorder(Color.CT.accent.opacity(0.5), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("security_notice_acknowledge", comment: ""))

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, CTLayout.edgePad)
            .padding(.vertical, CTLayout.chromeGap)
            .background(Color.CT.danger.opacity(0.10))
            .clipShape(CTShape.card())
            .overlay(CTShape.card().stroke(Color.CT.danger.opacity(0.45), lineWidth: 1))
            .padding(.horizontal, ChatUIConstants.Shell.auxOuterPad)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }
}
