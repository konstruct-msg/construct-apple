//
//  BackgroundFetchSettingsView.swift
//  Construct Messenger
//
//  Created by Auto on 03.01.2026.
//

import SwiftUI

struct BackgroundFetchSettingsView: View {
    // MARK: - State
    @AppStorage("backgroundFetchEnabled") private var isEnabled: Bool = true
    @State private var intervalMinutes: Int = BackgroundFetchConfig.defaultIntervalMinutes
    @State private var isLowPowerModeEnabled: Bool = false
    @State private var showingLowPowerModeAlert = false
    private var fetchManager = BackgroundFetchManager.shared

    // MARK: - Body
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // MARK: - Enable/Disable section
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection {
                        HStack(spacing: 14) {
                            Image(systemName: toggleIconName)
                                .foregroundStyle(isEnabled ? Color.CT.accent : Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey("enable_background_fetch"))
                                    .font(CTFont.bold(16))
                                    .foregroundStyle(Color.CT.text)
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .onChange(of: isEnabled) { _, newValue in
                            handleToggleChange(newValue)
                        }
                    }
                    Text(LocalizedStringKey("background_fetch_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }

                // MARK: - Interval Settings section
                if isEnabled && !isLowPowerModeEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        ConstructSection(header: NSLocalizedString("background_fetch_interval_settings", comment: "").uppercased()) {
                            VStack(alignment: .leading, spacing: 12) {
                                intervalHeader
                                intervalSlider
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        Text(LocalizedStringKey("background_fetch_interval_footer"))
                            .font(CTFont.regular(11))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 20)
                    }
                }

                // MARK: - Status section
                ConstructSection(header: NSLocalizedString("status", comment: "").uppercased()) {
                    HStack(spacing: 14) {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusColor)
                            .frame(width: 22, alignment: .center)
                            .font(.system(size: 16))
                        Text(LocalizedStringKey("background_fetch_status"))
                            .font(CTFont.bold(16))
                            .foregroundStyle(Color.CT.text)
                        Spacer()
                        Text(statusText)
                            .font(CTFont.regular(14))
                            .foregroundStyle(Color.CT.textDim)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    if let lastFetch = fetchManager.lastFetchDate {
                        ConstructRowDivider(indent: 52)
                        HStack(spacing: 14) {
                            Image(systemName: "clock")
                                .foregroundStyle(Color.CT.textDim)
                                .frame(width: 22, alignment: .center)
                                .font(.system(size: 16))
                            Text(LocalizedStringKey("background_fetch_last_check"))
                                .font(CTFont.bold(16))
                                .foregroundStyle(Color.CT.text)
                            Spacer()
                            Text(formatLastCheckDate(lastFetch))
                                .font(CTFont.regular(14))
                                .foregroundStyle(Color.CT.textDim)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }

                // MARK: - Low Power Mode Warning section
                if isLowPowerModeEnabled {
                    ConstructSection(header: NSLocalizedString("background_fetch_energy_saving", comment: "").uppercased()) {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "battery.25")
                                .foregroundStyle(.orange)
                                .frame(width: 22, alignment: .center)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey("background_fetch_low_power_mode_title"))
                                    .font(CTFont.bold(16))
                                    .foregroundStyle(Color.CT.text)
                                Text(LocalizedStringKey("background_fetch_low_power_mode_description"))
                                    .font(CTFont.regular(12))
                                    .foregroundStyle(Color.CT.textDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
            .padding(.vertical, 20)
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.CT.bgMsg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(NSLocalizedString("background_fetch", comment: "").uppercased())
                    .font(CTFont.bold(13))
                    .foregroundStyle(Color.CT.text)
                    .tracking(4)
            }
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

    private var toggleIconName: String {
        isEnabled ? "arrow.clockwise.circle.fill" : "arrow.clockwise.circle"
    }

    private var statusIcon: String {
        if isLowPowerModeEnabled {
            return "battery.25"
        } else if isEnabled {
            return "checkmark.circle.fill"
        } else {
            return "xmark.circle.fill"
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
                    RoundedRectangle(cornerRadius: 8)
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
