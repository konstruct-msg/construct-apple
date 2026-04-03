//
//  AppearanceSettingsView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 31.12.2025.
//

import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("theme", comment: "")) {
                        ForEach(Array(AppTheme.allCases.enumerated()), id: \.element) { index, theme in
                            if index > 0 { ConstructRowDivider(indent: 52) }
                            Button {
                                appTheme = theme
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: theme.iconName)
                                        .foregroundStyle(theme.color)
                                        .frame(width: 22, alignment: .center)
                                        .font(.system(size: 16))
                                    Text(theme.displayName)
                                        .font(CTFont.bold(16))
                                        .foregroundStyle(Color.CT.text)
                                    Spacer()
                                    if appTheme == theme {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.CT.accent)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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
        .navigationTitle("appearance")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
    }
}

// MARK: - App Theme Enum
enum AppTheme: String, CaseIterable {
    case automatic = "automatic"
    case light = "light"
    case dark = "dark"

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

#Preview {
    NavigationStack {
        AppearanceSettingsView()
    }
}
