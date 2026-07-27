//
//  ChatKeyChangeBannerView.swift
//  Construct Messenger
//
//  First-class trust event: identity key changed (or KT failed).
//  Not a tiny nav badge — requires user attention.
//

import SwiftUI

/// Prominent banner for `.keyChanged` / `.failed` KT status.
///
/// Actions:
/// - **Verify** → open Safety Numbers (OOB compare)
/// - **Accept** → acknowledge the new key (clear warning; TOFU re-pin already stored)
struct ChatKeyChangeBannerView: View {
    let status: KTStatus
    let contactName: String
    let onVerify: () -> Void
    let onAccept: () -> Void

    private var isVisible: Bool {
        status == .keyChanged || status == .failed
    }

    private var titleKey: String {
        status == .failed ? "key_change_banner_title_failed" : "key_change_banner_title"
    }

    private var subtitle: String {
        if status == .failed {
            return NSLocalizedString("key_change_banner_subtitle_failed", comment: "")
        }
        return String(
            format: NSLocalizedString("key_change_banner_subtitle_fmt", comment: ""),
            contactName
        )
    }

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: CTLayout.chromeGap) {
                HStack(alignment: .top, spacing: CTLayout.chromeGap) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(CTFont.regular(18))
                        .foregroundStyle(Color.CT.danger)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString(titleKey, comment: ""))
                            .font(CTFont.bold(12))
                            .foregroundStyle(Color.CT.text)
                        Text(subtitle)
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: CTLayout.inlinePad) {
                    Button(action: onVerify) {
                        Text(NSLocalizedString("key_change_verify", comment: ""))
                            .font(CTFont.bold(12))
                            .foregroundStyle(Color.CT.bg)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.CT.danger)
                            .clipShape(CTShape.control())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("key_change_verify", comment: ""))

                    Button(action: onAccept) {
                        Text(NSLocalizedString("key_change_accept", comment: ""))
                            .font(CTFont.regular(12))
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
                    .accessibilityLabel(NSLocalizedString("key_change_accept", comment: ""))

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
