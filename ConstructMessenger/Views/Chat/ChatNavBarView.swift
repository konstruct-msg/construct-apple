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
    let canStartCall: Bool
    let onBack: () -> Void
    let onOpenProfile: () -> Void
    let onDoneEdit: () -> Void
    let onStartCall: () -> Void
    /// Offered by holding the call button (`CallModeButton`) while
    /// `CallsFeature.isVideoEnabled` is true.
    let onStartVideoCall: () -> Void
    let onToggleSearch: () -> Void
    /// Optional: tap the KT warning badge to jump to verify (key-change banner).
    var onKTWarningTap: (() -> Void)? = nil

    /// The call ↔ video switch, drawn over the whole bar: the capsule clips its contents, and
    /// the switch hangs below it.
    @State private var callSwitch: CallModeButton.Mode?? = nil

    var body: some View {
        HStack(alignment: .center, spacing: CTLayout.chromeGap) {
            leadingCluster
            Spacer(minLength: CTLayout.inlinePad)
            trailingCluster
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
        .glassCapsule()
        .overlayPreferenceValue(CallButtonBoundsKey.self) { anchor in
            GeometryReader { geo in
                if let choice = callSwitch, let anchor {
                    let frame = geo[anchor]
                    CallModeSwitch(choice: choice, width: frame.width)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: callSwitch != nil)
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
                if canStartCall {
                    CallModeButton(
                        size: CTLayout.hitTarget,
                        open: $callSwitch,
                        offersVideo: CallsFeature.isVideoEnabled,
                        onVoice: onStartCall,
                        onVideo: onStartVideoCall
                    )
                    .anchorPreference(key: CallButtonBoundsKey.self, value: .bounds) { $0 }
                }
                navIconButton(
                    systemName: "magnifyingglass",
                    size: CTLayout.navIconSizeLg,
                    weight: .medium,
                    accessibilityKey: "search_messages",
                    action: onToggleSearch
                )
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

private struct CallButtonBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
