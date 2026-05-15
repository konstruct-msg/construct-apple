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
                    CTSectionGroup {
                        Button {
                            if !isLowPowerModeEnabled {
                                isEnabled.toggle()
                                handleToggleChange(isEnabled)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey("enable_background_fetch"))
                                        .font(CTFont.regular(13))
                                        .foregroundColor(isLowPowerModeEnabled ? Color.CT.textDim.opacity(0.5) : Color.CT.text)
                                    if isLowPowerModeEnabled {
                                        Text(LocalizedStringKey("background_fetch_low_power_mode_warning"))
                                            .font(CTFont.regular(11))
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Text(isEnabled && !isLowPowerModeEnabled ? "[■ ON]" : "[□ OFF]")
                                    .font(CTFont.bold(12))
                                    .foregroundColor(isEnabled && !isLowPowerModeEnabled ? Color.CT.accent : Color.CT.textDim)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(LocalizedStringKey("background_fetch_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)

                    // MARK: - Interval Settings section
                    if isEnabled && !isLowPowerModeEnabled {
                        CTSettingsSectionHeader(title: NSLocalizedString("background_fetch_interval_settings", comment: "").uppercased())
                        CTSectionGroup {
                            VStack(alignment: .leading, spacing: 12) {
                                intervalHeader
                                intervalStepper
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                        }
                        Text(LocalizedStringKey("background_fetch_interval_footer"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    }

                    // MARK: - Status section
                    CTSettingsSectionHeader(title: NSLocalizedString("status", comment: "").uppercased())
                    CTSectionGroup {
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
                    }

                    // MARK: - Low Power Mode Warning section
                    if isLowPowerModeEnabled {
                        CTSettingsSectionHeader(title: NSLocalizedString("background_fetch_energy_saving", comment: "").uppercased())
                        CTSectionGroup {
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
                        }
                    }
                }
                .padding(.vertical, 20)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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

    // MARK: - Sub-views

    private var intervalHeader: some View {
        HStack {
            Text(LocalizedStringKey("background_fetch_interval"))
                .font(CTFont.bold(13))
                .foregroundStyle(Color.CT.text)
            Spacer()
            Text(BackgroundFetchConfig.formatInterval(intervalMinutes))
                .font(CTFont.regular(13))
                .foregroundStyle(Color.CT.accent)
        }
    }

    /// CT-style interval stepper: [-] current value [+]
    private var intervalStepper: some View {
        HStack(spacing: 0) {
            Button {
                let newVal = max(BackgroundFetchConfig.minIntervalMinutes, intervalMinutes - 5)
                if newVal != intervalMinutes {
                    intervalMinutes = newVal
                    handleIntervalChange(newVal)
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(intervalMinutes > BackgroundFetchConfig.minIntervalMinutes ? Color.CT.accent : Color.CT.textDim)
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.CT.noise)
                .frame(width: 1, height: 24)

            Spacer()

            // Preset chips: 5 · 15 · 30 · 60
            HStack(spacing: 8) {
                ForEach([5, 15, 30, 60], id: \.self) { preset in
                    Button {
                        intervalMinutes = preset
                        handleIntervalChange(preset)
                    } label: {
                        Text("\(preset)")
                            .font(CTFont.regular(11))
                            .foregroundColor(intervalMinutes == preset ? Color.CT.accent : Color.CT.textDim)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .overlay(
                                Rectangle()
                                    .stroke(intervalMinutes == preset ? Color.CT.accent : Color.CT.noise, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Rectangle()
                .fill(Color.CT.noise)
                .frame(width: 1, height: 24)

            Button {
                let newVal = min(BackgroundFetchConfig.maxIntervalMinutes, intervalMinutes + 5)
                if newVal != intervalMinutes {
                    intervalMinutes = newVal
                    handleIntervalChange(newVal)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(intervalMinutes < BackgroundFetchConfig.maxIntervalMinutes ? Color.CT.accent : Color.CT.textDim)
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay(
            Rectangle()
                .stroke(Color.CT.noise, lineWidth: 1)
        )
    }

    // MARK: - Computed Properties

    private var statusIcon: String {
        if isLowPowerModeEnabled { return "[!]" }
        return isEnabled ? "[ok]" : "[~]"
    }

    private var statusColor: Color {
        if isLowPowerModeEnabled { return .orange }
        return isEnabled ? Color.CT.accent : Color.CT.textDim
    }

    private var statusText: LocalizedStringKey {
        if isLowPowerModeEnabled { return "background_fetch_disabled_low_power" }
        return isEnabled ? "background_fetch_enabled" : "background_fetch_disabled"
    }

    // MARK: - Methods

    private func loadSettings() {
        intervalMinutes = BackgroundFetchConfig.intervalMinutes
        isEnabled = BackgroundFetchConfig.isEnabled
    }

    private func checkLowPowerMode() {
        let wasLowPowerMode = isLowPowerModeEnabled
        isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
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

// MARK: - Preview

#Preview {
    BackgroundFetchSettingsView()
        .preferredColorScheme(.dark)
}
