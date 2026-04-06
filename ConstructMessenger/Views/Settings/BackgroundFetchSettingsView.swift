//
//  BackgroundFetchSettingsView.swift
//  Construct Messenger
//
//  Created by Auto on 03.01.2026.
//

import SwiftUI

struct BackgroundFetchSettingsView: View {
    // MARK: - State
    @Environment(\.dismiss) private var dismiss
    @AppStorage("backgroundFetchEnabled") private var isEnabled: Bool = true
    @State private var intervalMinutes: Int = BackgroundFetchConfig.defaultIntervalMinutes
    @State private var isLowPowerModeEnabled: Bool = false
    @State private var showingLowPowerModeAlert = false
    private var fetchManager = BackgroundFetchManager.shared

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("background_fetch", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            ScrollView {
            VStack(spacing: 0) {

                // MARK: - Enable/Disable section
                CTSettingsSectionHeader(title: NSLocalizedString("enable_background_fetch", comment: "").uppercased())
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("enable_background_fetch"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        if isLowPowerModeEnabled {
                            Text(LocalizedStringKey("background_fetch_low_power_mode_warning"))
                                .font(CTFont.regular(11))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .tint(Color.CT.accent)
                        .disabled(isLowPowerModeEnabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .onChange(of: isEnabled) { _, newValue in
                    handleToggleChange(newValue)
                }
                Text(LocalizedStringKey("background_fetch_footer"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                CTSep()

                // MARK: - Interval Settings section
                if isEnabled && !isLowPowerModeEnabled {
                    CTSettingsSectionHeader(title: NSLocalizedString("background_fetch_interval_settings", comment: "").uppercased())
                    VStack(alignment: .leading, spacing: 12) {
                        intervalHeader
                        intervalSlider
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    Text(LocalizedStringKey("background_fetch_interval_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    CTSep()
                }

                // MARK: - Status section
                CTSettingsSectionHeader(title: NSLocalizedString("status", comment: "").uppercased())
                HStack {
                    Text(LocalizedStringKey("background_fetch_status"))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                    Spacer()
                    Text(statusIcon)
                        .font(CTFont.regular(13))
                        .foregroundColor(statusColor)
                    Text(statusText)
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if let lastFetch = fetchManager.lastFetchDate {
                    CTSep(style: .thin)
                    HStack {
                        Text(LocalizedStringKey("background_fetch_last_check"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Spacer()
                        Text(formatLastCheckDate(lastFetch))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                CTSep()

                // MARK: - Low Power Mode Warning section
                if isLowPowerModeEnabled {
                    CTSettingsSectionHeader(title: NSLocalizedString("background_fetch_energy_saving", comment: "").uppercased())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("background_fetch_low_power_mode_title"))
                            .font(CTFont.regular(13))
                            .foregroundColor(Color.CT.textDim)
                        Text(LocalizedStringKey("background_fetch_low_power_mode_description"))
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    CTSep()
                }
            }
            .padding(.vertical, 20)
        }
        .onAppear {
            loadSettings()
            checkLowPowerMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            checkLowPowerMode()
        }
        .alert("background_fetch_low_power_mode_alert_title", isPresented: $showingLowPowerModeAlert) {
            Button("ok", role: .cancel) { }
        } message: {
            Text("background_fetch_low_power_mode_alert_message")
        }
        }
        .background(Color.CT.bg.ignoresSafeArea())
    }

    // MARK: - Sub-views

    private var intervalHeader: some View {
        HStack {
            Text(LocalizedStringKey("background_fetch_interval"))
                .font(CTFont.bold(16))
                .foregroundStyle(Color.CT.text)
            Spacer()
            Text(BackgroundFetchConfig.formatInterval(intervalMinutes))
                .font(CTFont.regular(14))
                .foregroundStyle(Color.CT.textDim)
        }
    }

    private var intervalSlider: some View {
        Slider(
            value: Binding(
                get: { Double(intervalMinutes) },
                set: { intervalMinutes = Int($0) }
            ),
            in: Double(BackgroundFetchConfig.minIntervalMinutes)...Double(BackgroundFetchConfig.maxIntervalMinutes),
            step: 5
        ) {
            Text(LocalizedStringKey("interval"))
        } minimumValueLabel: {
            Text("\(BackgroundFetchConfig.minIntervalMinutes) min")
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
        } maximumValueLabel: {
            Text("\(BackgroundFetchConfig.maxIntervalMinutes) min")
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
        }
        .onChange(of: intervalMinutes) { _, newValue in
            handleIntervalChange(newValue)
        }
    }

    // MARK: - Computed Properties

    private var statusIcon: String {
        if isLowPowerModeEnabled {
            return "[!]"
        } else if isEnabled {
            return "[ok]"
        } else {
            return "[~]"
        }
    }

    private var statusColor: Color {
        if isLowPowerModeEnabled {
            return .orange
        } else if isEnabled {
            return Color.CT.accent
        } else {
            return Color.CT.textDim
        }
    }

    private var statusText: LocalizedStringKey {
        if isLowPowerModeEnabled {
            return "background_fetch_disabled_low_power"
        } else if isEnabled {
            return "background_fetch_enabled"
        } else {
            return "background_fetch_disabled"
        }
    }

    // MARK: - Methods

    private func loadSettings() {
        intervalMinutes = BackgroundFetchConfig.intervalMinutes
        isEnabled = BackgroundFetchConfig.isEnabled
    }

    private func checkLowPowerMode() {
        let wasLowPowerMode = isLowPowerModeEnabled
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        // If Low Power Mode was just enabled, show alert and disable
        if isLowPowerModeEnabled && !wasLowPowerMode && isEnabled {
            showingLowPowerModeAlert = true
            isEnabled = false
            fetchManager.disableBackgroundFetch()
        }
    }

    private func handleToggleChange(_ newValue: Bool) {
        if newValue {
            fetchManager.enableBackgroundFetch()
        } else {
            fetchManager.disableBackgroundFetch()
        }
    }

    private func handleIntervalChange(_ newValue: Int) {
        BackgroundFetchConfig.intervalMinutes = newValue
        fetchManager.updateFetchInterval(newValue)
    }

    private func formatLastCheckDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Quick Interval Button

struct QuickIntervalButton: View {
    let minutes: Int
    let current: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(minutes) min")
                .font(.caption)
                .fontWeight(current == minutes ? .semibold : .regular)
                .foregroundColor(current == minutes ? .white : Color.CT.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Rectangle()
                        .fill(current == minutes ? Color.CT.accent : Color.CT.noise)
                )
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BackgroundFetchSettingsView()
    }
        .preferredColorScheme(.dark)
}
