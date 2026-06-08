//
//  Rows.swift
//  ConstructUI
//
//  Copied verbatim from the app's ConstructRowComponents.swift. Pure SwiftUI —
//  depends only on Color.CT / CTFont from this package. Preview gallery at the
//  bottom; open this file's canvas to iterate on row styling.
//

import SwiftUI

// MARK: - Role

/// Visual role that controls the fill, border, and foreground color of a row.
enum ConstructRowRole {
    /// Primary action — electric-blue tint, strong accent border.
    case primary
    /// Accent action — lighter electric-blue tint.
    case accent
    /// Standard secondary action — neutral dark background.
    case secondary
    /// Destructive action — red tint.
    case destructive
    /// Coming-soon / unavailable — dimmed, shows "soon" badge.
    case disabled
}

// MARK: - Action Row (button-style, full-width rounded card)

/// A full-width tappable row styled according to `ConstructRowRole`.
struct ConstructActionRow: View {

    let systemImage: String
    let title: LocalizedStringKey
    let role: ConstructRowRole
    var badge: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            guard role != .disabled, !isLoading else { return }
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(rowForeground)
                    .frame(minWidth: 20, alignment: .center)

                Text(title)
                    .font(CTFont.bold(16))

                Spacer()

                if isLoading {
                    ProgressView().scaleEffect(0.75)
                } else if role == .disabled {
                    badgeView(badge ?? "soon")
                } else if let badge {
                    badgeView(badge)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(rowFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(rowBorder, lineWidth: 1))
            .foregroundStyle(rowForeground)
        }
        .buttonStyle(.plain)
        .disabled(role == .disabled || isLoading)
    }

    private func badgeView(_ text: String) -> some View {
        Text(text)
            .font(CTFont.regular(10))
            .foregroundStyle(Color.CT.textDim)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Rectangle().fill(Color.CT.bgMsg))
    }

    private var rowFill: Color {
        switch role {
        case .primary:     return Color.CT.accent.opacity(0.12)
        case .accent:      return Color.CT.accent.opacity(0.08)
        case .destructive: return Color.red.opacity(0.10)
        default:           return Color.CT.bgMsg
        }
    }

    private var rowBorder: Color {
        switch role {
        case .primary:     return Color.CT.accent.opacity(0.35)
        case .accent:      return Color.CT.accent.opacity(0.25)
        case .destructive: return Color.red.opacity(0.30)
        default:           return Color.CT.noise
        }
    }

    private var rowForeground: Color {
        switch role {
        case .primary, .accent: return Color.CT.accent
        case .destructive:      return Color.red
        case .disabled:         return Color.CT.textDim
        case .secondary:        return Color.CT.text
        }
    }
}

// MARK: - Settings Nav Row (NavigationLink with chevron)

/// A settings-list row that pushes to a destination view.
struct ConstructNavRow<Destination: View>: View {

    let icon: String
    let title: LocalizedStringKey
    var iconColor: Color = Color.CT.accent
    let destination: Destination

    var body: some View {
        NavigationLink(destination: destination) {
            rowContent
        }
        .buttonStyle(.plain)
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            navIconView(icon, color: iconColor)
                .frame(minWidth: 22, alignment: .center)

            Text(title)
                .font(CTFont.bold(16))
                .foregroundStyle(Color.CT.text)

            Spacer()

            Text("[→]")
                .font(CTFont.regular(12))
                .foregroundStyle(Color.CT.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func navIconView(_ icon: String, color: Color) -> some View {
        if icon.hasPrefix("[") || icon.hasPrefix("●") {
            Text(icon)
                .font(CTFont.regular(13))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
        } else {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
        }
    }
}

// MARK: - Settings Button Row (tap action, no chevron by default)

/// A settings-list row that triggers an action.
struct ConstructButtonRow: View {

    let systemImage: String
    let title: LocalizedStringKey
    var iconColor: Color = Color.CT.accent
    var showChevron: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(minWidth: 22, alignment: .center)

                Text(title)
                    .font(CTFont.bold(16))
                    .foregroundStyle(Color.CT.text)

                Spacer()

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.CT.textDim)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Row Divider

/// Thin Construct-styled divider with standard left indent.
struct ConstructRowDivider: View {
    var indent: CGFloat = 54

    var body: some View {
        Divider()
            .overlay(Color.CT.noise)
            .padding(.leading, indent)
    }
}

// MARK: - Preview gallery

#Preview("Rows") {
    ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            Text("> ACTION ROWS")
                .font(CTFont.bold(13)).foregroundStyle(Color.CT.accent)
            ConstructActionRow(systemImage: "bolt.fill", title: "Primary", role: .primary) {}
            ConstructActionRow(systemImage: "sparkles", title: "Accent", role: .accent) {}
            ConstructActionRow(systemImage: "gearshape", title: "Secondary", role: .secondary) {}
            ConstructActionRow(systemImage: "trash", title: "Destructive", role: .destructive) {}
            ConstructActionRow(systemImage: "clock", title: "Disabled", role: .disabled) {}
            ConstructActionRow(systemImage: "arrow.clockwise", title: "Loading", role: .primary, isLoading: true) {}

            Text("> SETTINGS ROWS")
                .font(CTFont.bold(13)).foregroundStyle(Color.CT.accent)
                .padding(.top, 8)
            ConstructButtonRow(systemImage: "person.crop.circle", title: "Identity", showChevron: true) {}
            ConstructRowDivider()
            ConstructButtonRow(systemImage: "lock.shield", title: "Security") {}
        }
        .padding(20)
    }
    .background(Color.CT.bg)
}
