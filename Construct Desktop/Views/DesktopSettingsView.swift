//
//  DesktopSettingsView.swift
//  Construct Desktop
//
//  CT-terminal-style Settings window (⌘,).
//  Sidebar list of ASCII-labelled sections + content pane.
//

import SwiftUI

struct DesktopSettingsView: View {

    enum Section: String, CaseIterable, Identifiable {
        case account        = "IDENTITY"
        case appearance     = "APPEARANCE"
        case general        = "GENERAL"
        case security       = "SECURITY"
        case notifications  = "NOTIFICATIONS"
        case storage        = "STORAGE"
        case transcription  = "TRANSCRIPTION"
        case network        = "NETWORK"
        case diagnostics    = "DIAGNOSTICS"

        var id: String { rawValue }
    }

    @State private var selected: Section = .account

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar
            VStack(alignment: .leading, spacing: 0) {
                Text("SETTINGS")
                    .font(CTFont.bold(11))
                    .foregroundStyle(Color.CT.accent)
                    .tracking(3)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 14)

                Rectangle()
                    .fill(Color.CT.noise)
                    .frame(height: 1)
                    .padding(.bottom, 6)

                ForEach(Section.allCases) { section in
                    sidebarRow(section)
                }

                Spacer()
            }
            .frame(width: 180)
            .ctBackground()

            // Separator
            Rectangle()
                .fill(Color.CT.noise)
                .frame(width: 1)

            // MARK: Content pane
            Group {
                switch selected {
                case .account:       DesktopAccountSettingsTab()
                case .appearance:    DesktopAppearanceSettingsTab()
                case .general:       DesktopGeneralSettingsTab()
                case .security:      DesktopSecuritySettingsTab()
                case .notifications:  DesktopNotificationsSettingsTab()
                case .storage:        DesktopStorageSettingsTab()
                case .transcription:  DesktopTranscriptionSettingsTab()
                case .network:        DesktopNetworkSettingsTab()
                case .diagnostics:   DesktopDiagnosticsSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ctBackground()
        }
        .frame(width: 720, height: 560)
    }

    private func sidebarRow(_ section: Section) -> some View {
        let isActive = selected == section
        return Button {
            selected = section
        } label: {
            HStack(spacing: 8) {
                if isActive {
                    Rectangle()
                        .fill(Color.CT.accent)
                        .frame(width: 2, height: 14)
                }
                Text(section.rawValue)
                    .font(CTFont.regular(12))
                    .foregroundStyle(isActive ? Color.CT.accent : Color.CT.textDim)
                    .tracking(isActive ? 1 : 0)
                Spacer()
            }
            .padding(.leading, isActive ? 12 : 16)
            .padding(.vertical, 8)
            .background(isActive ? Color.CT.accent.opacity(0.07) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Account

private struct DesktopAccountSettingsTab: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @State private var showSignOutConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DesktopAccountSettingsView()

                CTSep(style: .thick)
                CTSettingsSectionHeader(title: NSLocalizedString("session_section", comment: ""))

                Button {
                    showSignOutConfirm = true
                } label: {
                    HStack {
                        Text(NSLocalizedString("sign_out", comment: ""))
                            .font(CTFont.regular(13))
                            .foregroundStyle(Color.CT.danger)
                        Spacer()
                        Text("[→]").font(CTFont.regular(12)).foregroundStyle(Color.CT.danger.opacity(0.6))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
        }
        .background(Color.CT.bg)
        .alert(NSLocalizedString("sign_out_confirm_title", comment: ""), isPresented: $showSignOutConfirm) {
            Button(NSLocalizedString("sign_out_confirm_action", comment: ""), role: .destructive) {
                authViewModel.logout()
            }
            Button(NSLocalizedString("cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("sign_out_confirm_message", comment: ""))
        }
    }
}

// MARK: - General

private struct DesktopGeneralSettingsTab: View {
    @AppStorage("desktopSendOnEnter") private var sendOnEnter: Bool = true
    @AppStorage("desktopShowTimestamps") private var showTimestamps: Bool = true

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Composing
                CTSettingsSectionHeader(title: NSLocalizedString("composing", comment: ""))
                HStack {
                    Text(NSLocalizedString("send_on_enter", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.text)
                    Spacer()
                    Toggle("", isOn: $sendOnEnter)
                        .labelsHidden()
                        .tint(Color.CT.accent)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                CTSep(style: .thick)

                // Messages
                CTSettingsSectionHeader(title: NSLocalizedString("message_section", comment: ""))
                HStack {
                    Text(NSLocalizedString("show_timestamps", comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.text)
                    Spacer()
                    Toggle("", isOn: $showTimestamps)
                        .labelsHidden()
                        .tint(Color.CT.accent)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                Spacer()
            }
            .padding(.bottom, 24)
        }
        .background(Color.CT.bg)
    }
}

// Re-declare for Desktop (small enum; shared one lives in AppearanceSettingsView)
enum DesktopTextSize: String, CaseIterable {
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

// MARK: - Appearance (top-level, as requested)
private struct DesktopAppearanceSettingsTab: View {
    @AppStorage("appTheme") private var appTheme: AppTheme = .automatic
    @AppStorage("textSize") private var textSize: DesktopTextSize = .standard

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Theme
                CTSettingsSectionHeader(title: NSLocalizedString("theme", comment: ""))
                CTSectionGroup {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        if theme != AppTheme.allCases.first { CTSep(style: .thin) }
                        Button {
                            appTheme = theme
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: theme.iconName)
                                    .font(.system(size: 14))
                                    .foregroundStyle(appTheme == theme ? Color.CT.accent : Color.CT.textDim)
                                    .frame(width: 24, alignment: .leading)
                                Text(LocalizedStringKey(theme.rawValue.capitalized))
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(appTheme == theme ? Color.CT.text : Color.CT.textDim)
                                Spacer()
                                if appTheme == theme {
                                    Text("[✓]")
                                        .font(CTFont.regular(12))
                                        .foregroundStyle(Color.CT.accent)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                CTSep(style: .thick)

                // Text size (controls CTFont scaling via UserDefaults "textSize")
                CTSettingsSectionHeader(title: NSLocalizedString("text_size", comment: ""))
                CTSectionGroup {
                    ForEach(DesktopTextSize.allCases, id: \.self) { size in
                        if size != DesktopTextSize.allCases.first { CTSep(style: .thin) }
                        Button {
                            textSize = size
                        } label: {
                            HStack(spacing: 10) {
                                Text(size.displayName)
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(textSize == size ? Color.CT.text : Color.CT.textDim)
                                Spacer()
                                if textSize == size {
                                    Text("[✓]")
                                        .font(CTFont.regular(12))
                                        .foregroundStyle(Color.CT.accent)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(LocalizedStringKey("text_size_footer"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                Spacer()
            }
            .padding(.bottom, 24)
        }
        .background(Color.CT.bg)
    }
}

// MARK: - Security

private struct DesktopSecuritySettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // E2E Encryption info
                CTSettingsSectionHeader(title: NSLocalizedString("encryption_section", comment: ""))
                infoRow(NSLocalizedString("e2e_protocol", comment: ""),
                        value: "Double Ratchet + Kyber-1024 (PQC)")
                CTSep(style: .thin)
                infoRow(NSLocalizedString("e2e_forward_secrecy", comment: ""),
                        value: "Per-message ratchet")
                CTSep(style: .thin)
                infoRow(NSLocalizedString("e2e_key_agreement", comment: ""),
                        value: "PQXDH (X25519 + Kyber KEM)")

                CTSep(style: .thick)

                DesktopSecurityView()

                Spacer()
            }
            .padding(.bottom, 24)
        }
        .background(Color.CT.bg)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(CTFont.regular(13))
                .foregroundStyle(Color.CT.textDim)
            Spacer()
            Text(value)
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

// MARK: - Notifications

private struct DesktopNotificationsSettingsTab: View {
    var body: some View {
        NotificationsSettingsView(showNavBar: false)
    }
}

// MARK: - Storage

private struct DesktopStorageSettingsTab: View {
    var body: some View {
        DataStorageSettingsView(showNavBar: false)
    }
}

// MARK: - Transcription

private struct DesktopTranscriptionSettingsTab: View {
    var body: some View {
        ScrollView {
            STTSettingsSection()
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Network

private struct DesktopNetworkSettingsTab: View {
    var body: some View {
        NetworkSettingsView(showNavBar: false)
    }
}

// MARK: - Diagnostics

private struct DesktopDiagnosticsSettingsTab: View {
    var body: some View {
        DiagnosticsView(showNavBar: false)
    }
}

#Preview {
    DesktopSettingsView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(SecurityViewModel())
        .environment(AccountRecoveryViewModel())
}
