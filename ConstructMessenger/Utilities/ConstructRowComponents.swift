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
                    .font(ConstructFont.display(16))

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
            .font(ConstructFont.mono(10))
            .foregroundStyle(Color.Construct.textDim)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.Construct.bg3))
    }

    private var rowFill: Color {
        switch role {
        case .primary:     return Color.Construct.accent.opacity(0.12)
        case .accent:      return Color.Construct.accent.opacity(0.08)
        case .destructive: return Color.red.opacity(0.10)
        default:           return Color.Construct.bg2
        }
    }

    private var rowBorder: Color {
        switch role {
        case .primary:     return Color.Construct.accent.opacity(0.35)
        case .accent:      return Color.Construct.accent.opacity(0.25)
        case .destructive: return Color.red.opacity(0.30)
        default:           return Color.Construct.line
        }
    }

    private var rowForeground: Color {
        switch role {
        case .primary, .accent: return Color.Construct.accent
        case .destructive:      return Color.red
        case .disabled:         return Color.Construct.textDim
        case .secondary:        return Color.Construct.text
        }
    }
}

// MARK: - Settings Nav Row (NavigationLink with chevron)

/// A settings-list row that pushes to a destination view.
struct ConstructNavRow<Destination: View>: View {

    let icon: String
    let title: LocalizedStringKey
    var iconColor: Color = Color.Construct.accent
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
                .font(ConstructFont.display(16))
                .foregroundStyle(Color.Construct.text)

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Construct.textDim)
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
    var iconColor: Color = Color.Construct.accent
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
                    .font(ConstructFont.display(16))
                    .foregroundStyle(Color.Construct.text)

                Spacer()

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.Construct.textDim)
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
            .overlay(Color.Construct.line)
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
                    .font(ConstructFont.mono(10, weight: .semibold))
                    .foregroundStyle(Color.Construct.textDim)
                    .tracking(1.5)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.Construct.bg2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.Construct.line, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 16)
    }
}
