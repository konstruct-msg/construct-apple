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
    let isEditMode: Bool
    let canStartCall: Bool
    let isSearchActive: Bool
    let onBack: () -> Void
    let onOpenProfile: () -> Void
    let onDoneEdit: () -> Void
    let onStartCall: () -> Void
    /// Always non-nil so the layout is stable; rendered only when
    /// `CallsFeature.isVideoEnabled` is true.
    let onStartVideoCall: () -> Void
    let onToggleSearch: () -> Void
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

            Button(action: onOpenProfile) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased())
                        .font(CTFont.bold(14))
                        .foregroundColor(Color.CT.text)
                        .tracking(4)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(CTFont.regular(10))
                            .foregroundColor(Color.CT.accentDim)
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
                    if CallsFeature.isVideoEnabled {
                        navIconButton(
                            systemName: "video.fill",
                            size: CTLayout.navIconSizeLg,
                            weight: .medium,
                            accessibilityKey: "call_video",
                            action: onStartVideoCall
                        )
                    }
                    navIconButton(
                        systemName: "phone",
                        size: CTLayout.navIconSizeLg,
                        weight: .medium,
                        accessibilityKey: "call_voice",
                        action: onStartCall
                    )
                }
                navIconButton(
                    systemName: isSearchActive ? "xmark" : "magnifyingglass",
                    size: CTLayout.navIconSizeLg,
                    weight: .medium,
                    accessibilityKey: isSearchActive ? "close" : "search_messages",
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
        switch contactKTStatus {
        case .verified:
            Image(systemName: "checkmark.circle.fill")
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.accent)
                .accessibilityLabel(Text(LocalizedStringKey("kt_verified")))
        case .keyChanged, .failed:
            Button {
                onKTWarningTap?()
            } label: {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(CTFont.bold(14))
                    .foregroundColor(Color.CT.danger)
                    .frame(width: CTLayout.hitTarget * 0.7, height: CTLayout.hitTarget * 0.7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("kt_warning")))
            .accessibilityHint(Text(LocalizedStringKey("key_change_verify")))
        case .unverified:
            EmptyView()
        }
    }
}

