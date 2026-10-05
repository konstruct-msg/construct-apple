//
//  ChatNavBarView.swift
//  Construct Messenger
//
//  Floating glass chat navigation — uses CTLayout hit targets and icon scale.
//

import SwiftUI

struct ChatNavBarView: View {
    let title: String
    let subtitle: String?
    let contactKTStatus: KTStatus
    /// A pending security event or a failed proof; outranks the verified check.
    var contactTrustAlert: ContactTrustAlert? = nil
    let isEditMode: Bool
    let onBack: () -> Void
    let onOpenProfile: () -> Void
    let onDoneEdit: () -> Void
    /// Search, call, video call — one button, one palette (`ChatActionButton`). The palette itself
    /// is drawn by the chat, over everything; this bar only places the button.
    let actions: [ChatAction]
    @Binding var actionPalette: ChatActionPaletteState?
    let onAction: (ChatAction) -> Void
    /// Optional: tap the KT warning badge to jump to verify (key-change banner).
    var onKTWarningTap: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            leadingCluster
            Spacer(minLength: CTLayout.inlinePad)
            trailingCluster
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
        .glassCapsule()
    }

    // MARK: - Leading

    private var leadingCluster: some View {
        HStack(alignment: .center, spacing: CTLayout.inlinePad) {
            navIconButton(
                systemName: "chevron.backward.circle.fill",
                size: CTLayout.navIconSizeLg,
                weight: .regular,
                accessibilityKey: "chat_nav_back",
                action: onBack
            )
            .accessibilityIdentifier(A11y.Chat.back)

            Button(action: onOpenProfile) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased())
                        .font(CTFont.headline)
                        .foregroundColor(Color.CT.text)
                        .tracking(4)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(CTFont.micro)
                            .foregroundColor(Color.CT.accent)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                // Title is flexible but stays vertically centered with 44pt peers.
                .frame(minHeight: CTLayout.hitTarget, alignment: .center)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .accessibilityIdentifier(A11y.Chat.title)

            ktBadge
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingCluster: some View {
        HStack(alignment: .center, spacing: 0) {
            if isEditMode {
                navIconButton(
                    systemName: "checkmark.circle.fill",
                    size: CTLayout.navIconSizeLg,
                    weight: .regular,
                    accessibilityKey: "done",
                    action: onDoneEdit
                )
            } else {
                ChatActionButton(actions: actions, palette: $actionPalette, onAction: onAction)
                    .anchorPreference(key: ChatActionButtonAnchorKey.self, value: .bounds) { $0 }
            }
        }
    }

    // MARK: - Shared control

    /// Square hit target (`CTLayout.hitTarget`) with centered SF Symbol — prevents
    /// optical hang and under-sized taps when icons differ (filled vs outline).
    private func navIconButton(
        systemName: String,
        size: CGFloat,
        weight: Font.Weight,
        accessibilityKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundColor(Color.CT.accent)
                .frame(width: CTLayout.hitTarget, height: CTLayout.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(accessibilityKey, comment: ""))
    }

    @ViewBuilder private var ktBadge: some View {
        if contactTrustAlert != nil {
            Button {
                onKTWarningTap?()
            } label: {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(CTFont.headline)
                    .foregroundColor(Color.CT.danger)
                    .frame(width: CTLayout.hitTarget * 0.7, height: CTLayout.hitTarget * 0.7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("kt_warning")))
            .accessibilityHint(Text(LocalizedStringKey("key_change_verify")))
        } else if contactKTStatus == .verified {
            Image(systemName: "checkmark.circle.fill")
                .font(CTFont.caption)
                .foregroundColor(Color.CT.accent)
                .accessibilityLabel(Text(LocalizedStringKey("kt_verified")))
        }
    }
}

