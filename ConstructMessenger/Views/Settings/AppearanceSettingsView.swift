//
//  AppearanceSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 31.12.2025.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .dark
    @AppStorage("textSize") private var textSize: TextSize = .standard
    @Environment(\.dismiss) private var dismiss
    private let allThemes = AppTheme.allCases

    var body: some View {
        ScrollView {
            LazyVStack(spacing: SettingsLayout.sectionSpacing) {
                CTNavBar(
                    title: NSLocalizedString("appearance", comment: ""),
                    showBack: true,
                    backAction: { dismiss() }
                ) {
                    EmptyView()
                } trailing: {
                    EmptyView()
                }
                
                VStack(alignment: .leading, spacing: SettingsLayout.sectionHeaderSpacing) {
                    VStack(alignment: .leading, spacing: 0) {
                        CTSettingsSectionHeader(title: NSLocalizedString("theme", comment: ""))
                        CTSectionGroup {
                            let themes = allThemes
                            ForEach(Array(themes.enumerated()), id: \.offset) { pair in
                                let index = pair.offset
                                let theme = pair.element
                                if index > 0 { ConstructRowDivider(indent: SettingsLayout.rowDividerIndent) }
                                Button {
                                    guard theme.isAvailable else { return }
                                    appTheme = theme
                                } label: {
                                    HStack(spacing: AppearanceSettingsLayout.themeRowContentSpacing) {
                                        CTRowIcon(
                                            sf: theme.iconName,
                                            color: theme.isAvailable ? theme.color : Color.CT.textDim
                                        )
                                        Text(theme.displayName)
                                            .font(CTFont.bold(16))
                                            .foregroundStyle(theme.isAvailable ? Color.CT.text : Color.CT.textDim)
                                        Spacer()
                                        if !theme.isAvailable {
                                            Text(LocalizedStringKey("settings_coming_soon"))
                                                .font(CTFont.regular(10))
                                                .foregroundStyle(Color.CT.textDim)
                                                .padding(.horizontal, AppearanceSettingsConfig.availabilityBadgeHorizontalPadding)
                                                .padding(.vertical, AppearanceSettingsConfig.availabilityBadgeVerticalPadding)
                                                .overlay(
                                                    Rectangle()
                                                        .strokeBorder(Color.CT.noise, lineWidth: AppearanceSettingsConfig.availabilityBadgeStrokeWidth)
                                                )
                                        } else if appTheme == theme {
                                            Text("[✓]")
                                                .font(CTFont.bold(14))
                                                .foregroundStyle(Color.CT.accent)
                                        }
                                    }
                                    .padding(.horizontal, AppearanceSettingsLayout.themeRowHorizontalPadding)
                                    .padding(.vertical, AppearanceSettingsLayout.themeRowVerticalPadding)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!theme.isAvailable)
                            }
                        }
                    }
                    Text(LocalizedStringKey("theme_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
                }

                // MARK: - Text size (moved from hardcoded; applies to CTFont)
                VStack(alignment: .leading, spacing: SettingsLayout.sectionHeaderSpacing) {
                    CTSettingsSectionHeader(title: NSLocalizedString("text_size", comment: ""))
                    CTSectionGroup {
                        ForEach(TextSize.allCases, id: \.self) { size in
                            if size != TextSize.allCases.first { ConstructRowDivider(indent: SettingsLayout.rowDividerIndent) }
                            Button {
                                textSize = size
                            } label: {
                                HStack(spacing: AppearanceSettingsLayout.themeRowContentSpacing) {
                                    Text(size.displayName)
                                        .font(CTFont.bold(16))
                                        .foregroundStyle(Color.CT.text)
                                    Spacer()
                                    if textSize == size {
                                        Text("[✓]")
                                            .font(CTFont.bold(14))
                                            .foregroundStyle(Color.CT.accent)
                                    }
                                }
                                .padding(.horizontal, AppearanceSettingsLayout.themeRowHorizontalPadding)
                                .padding(.vertical, AppearanceSettingsLayout.themeRowVerticalPadding)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(LocalizedStringKey("text_size_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
                }
            }
            .padding(.vertical, SettingsLayout.screenVerticalPadding)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
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

// MARK: - Text size (for CTFont scaling in Appearance)
enum TextSize: String, CaseIterable {
    case compact = "compact"
    case standard = "standard"
    case large = "large"

    var displayName: LocalizedStringKey {
        switch self {
        case .compact: return "compact"
        case .standard: return "standard"
        case .large: return "large"
        }
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
    }
        .preferredColorScheme(.dark)
}
