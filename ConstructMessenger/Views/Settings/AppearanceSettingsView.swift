//
//  AppearanceSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 31.12.2025.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .dark
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CTNavBar(
                    title: NSLocalizedString("appearance", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                )
                
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("theme", comment: "")) {
                        ForEach(Array(AppTheme.allCases.enumerated()), id: \.element) { index, theme in
                            if index > 0 { ConstructRowDivider(indent: 52) }
                            Button {
                                guard theme.isAvailable else { return }
                                appTheme = theme
                            } label: {
                                HStack(spacing: 14) {
                                    CTRowIcon(theme.asciiIcon,
                                              color: theme.isAvailable ? theme.color : Color.CT.textDim)
                                    Text(theme.displayName)
                                        .font(CTFont.bold(16))
                                        .foregroundStyle(theme.isAvailable ? Color.CT.text : Color.CT.textDim)
                                    Spacer()
                                    if !theme.isAvailable {
                                        Text("soon")
                                            .font(CTFont.regular(10))
                                            .foregroundStyle(Color.CT.textDim)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .overlay(
                                                Rectangle()
                                                    .strokeBorder(Color.CT.noise, lineWidth: 1)
                                            )
                                    } else if appTheme == theme {
                                        Text("[✓]")
                                            .font(CTFont.bold(14))
                                            .foregroundStyle(Color.CT.accent)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!theme.isAvailable)
                        }
                    }
                    Text(LocalizedStringKey("theme_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 20)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            // If user previously selected an unavailable theme, reset to dark
            if !appTheme.isAvailable { appTheme = .dark }
        }
    }
}

// MARK: - App Theme Enum
enum AppTheme: String, CaseIterable {
    case automatic = "automatic"
    case light = "light"
    case dark = "dark"

    /// Only dark theme is currently implemented.
    var isAvailable: Bool { true }

    var displayName: LocalizedStringKey {
        switch self {
        case .automatic: return "automatic"
        case .light: return "light"
        case .dark: return "dark"
        }
    }

    var asciiIcon: String {
        switch self {
        case .automatic: return "[◐]"
        case .light:     return "[□]"
        case .dark:      return "[■]"
        }
    }

    var iconName: String {
        switch self {
        case .automatic: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var color: Color {
        switch self {
        case .automatic: return Color.CT.textDim
        case .light: return .orange
        case .dark: return Color.CT.accent
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
    }
        .preferredColorScheme(.dark)
}
