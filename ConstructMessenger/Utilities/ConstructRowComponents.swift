//
//  ConstructRowComponents.swift
//  Construct Messenger
//
//  Reusable row components using the Construct design system.
//  Used in UserProfileView, SettingsView, AccountSettingsView, and all other settings screens.
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
/// Used for actions inside profile cards, settings sections, etc.
struct ConstructActionRow: View {

    let icon: String
    let title: LocalizedStringKey
    let role: ConstructRowRole
    var badge: String? = nil          // optional trailing text badge (e.g. "soon")
    var isLoading: Bool = false       // shows ProgressView instead of chevron when true
    let action: () -> Void

    var body: some View {
        Button {
            guard role != .disabled, !isLoading else { return }
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 20, alignment: .center)
                    .font(.system(size: 16))

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
            .background(
                RoundedRectangle(cornerRadius: 13)
                    .fill(rowFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(rowBorder, lineWidth: 1)
                    )
            )
            .foregroundStyle(rowForeground)
        }
        .buttonStyle(.plain)
        .disabled(role == .disabled || isLoading)
    }

    // MARK: Private helpers

    private func badgeView(_ text: String) -> some View {
        Text(text)
            .font(CTFont.regular(10))
            .foregroundStyle(Color.CT.textDim)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.CT.bgMsg))
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
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 22, alignment: .center)
                .font(.system(size: 16))

            Text(title)
                .font(CTFont.bold(16))
                .foregroundStyle(Color.CT.text)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.CT.textDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Settings Button Row (tap action, no chevron by default)

/// A settings-list row that triggers an action.
struct ConstructButtonRow: View {

    let icon: String
    let title: LocalizedStringKey
    var iconColor: Color = Color.CT.accent
    var showChevron: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 22, alignment: .center)
                    .font(.system(size: 16))

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

// MARK: - Settings Section Container

/// Dark rounded card used as a settings section container.
struct ConstructSection<Content: View>: View {

    var header: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                Text(header.uppercased())
                    .font(CTFont.bold(10))
                    .foregroundStyle(Color.CT.textDim)
                    .tracking(1.5)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.CT.bgMsg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.CT.noise, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 16)
    }
}
