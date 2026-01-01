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
        List {
            Section {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Button {
                        appTheme = theme
                    } label: {
                        HStack {
                            Image(systemName: theme.iconName)
                                .foregroundColor(theme.color)

                            Text(theme.displayName)
                                .foregroundColor(.primary)

                            Spacer()

                            if appTheme == theme {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Choose how Construct Messenger looks. Automatic adjusts based on your system settings.")
                    .font(.caption)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - App Theme Enum
enum AppTheme: String, CaseIterable {
    case automatic = "automatic"
    case light = "light"
    case dark = "dark"

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
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
        case .automatic: return .blue
        case .light: return .orange
        case .dark: return .indigo
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
