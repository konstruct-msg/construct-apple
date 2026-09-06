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
    @AppStorage(ChatTextPreference.faceKey) private var chatFace: ChatTextPreference.Face = .mono
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
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 14, weight: .semibold))
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

                // MARK: - Message font
                //
                // Scoped to message text — bubbles and the composer that fills them — and nothing
                // else. Monospace is the language of the chrome; what a person writes and reads is
                // content. See `CTFont.message`.
                VStack(alignment: .leading, spacing: SettingsLayout.sectionHeaderSpacing) {
                    CTSettingsSectionHeader(title: NSLocalizedString("chat_font", comment: ""))
                    CTSectionGroup {
                        ForEach(ChatTextPreference.Face.allCases, id: \.self) { face in
                            if face != ChatTextPreference.Face.allCases.first {
                                ConstructRowDivider(indent: SettingsLayout.rowDividerIndent)
                            }
                            Button {
                                chatFace = face
                            } label: {
                                HStack(spacing: AppearanceSettingsLayout.themeRowContentSpacing) {
                                    // The row is set in the face it offers, so the choice is
                                    // visible before it is made. `CTFont.message` cannot be used
                                    // here — it reads the current preference, which would render
                                    // both rows in the selected face and show nothing.
                                    Text(face.displayName)
                                        .font(face == .mono ? CTFont.bold(16) : .system(size: 16, weight: .bold))
                                        .foregroundStyle(Color.CT.text)
                                    Spacer()
                                    if chatFace == face {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
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
                    Text(LocalizedStringKey("chat_font_footer"))
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
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
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
        .hideSystemNavBar()
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

    /// Resolved here rather than returned as a `LocalizedStringKey`: a bare literal typed as a
    /// key localizes correctly and is invisible to `scripts/check_localization.sh`, so a missing
    /// entry ships green. See the note in that script.
    var displayName: String {
        switch self {
        case .automatic: return NSLocalizedString("automatic", comment: "")
        case .light:     return NSLocalizedString("light", comment: "")
        case .dark:      return NSLocalizedString("dark", comment: "")
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
extension ChatTextPreference.Face {
    var displayName: String {
        switch self {
        case .mono:   return NSLocalizedString("chat_font_mono", comment: "")
        case .system: return NSLocalizedString("chat_font_system", comment: "")
        }
    }
}

enum TextSize: String, CaseIterable {
    case compact = "compact"
    case standard = "standard"
    case large = "large"

    /// Namespaced like `chat_font_*`. The bare `"compact"` / `"standard"` / `"large"` these
    /// replace had no entry in any locale, so all three rows rendered their own key. A one-word
    /// key is also the kind that later collides with an unrelated screen's noun.
    var displayName: String {
        switch self {
        case .compact:  return NSLocalizedString("text_size_compact", comment: "")
        case .standard: return NSLocalizedString("text_size_standard", comment: "")
        case .large:    return NSLocalizedString("text_size_large", comment: "")
        }
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
    }
        .preferredColorScheme(.dark)
}
