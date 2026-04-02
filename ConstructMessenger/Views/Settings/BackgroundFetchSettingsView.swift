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
        List {
            enableDisableSection
            intervalSettingsSection
            statusSection
            lowPowerModeWarningSection
        }
        .navigationTitle("background_fetch")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
    
    // MARK: - View Sections
    
    private var enableDisableSection: some View {
        Section {
            Toggle(isOn: $isEnabled) {
                Label {
                    toggleLabelContent
                } icon: {
                    Image(systemName: toggleIconName)
                        .foregroundColor(toggleIconColor)
                }
            }
            .disabled(isLowPowerModeEnabled)
            .onChange(of: isEnabled) { _, newValue in
                handleToggleChange(newValue)
            }
        } footer: {
            Text("background_fetch_footer")
                .font(.caption)
        }
    }
    
    private var toggleLabelContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("enable_background_fetch")
            if isLowPowerModeEnabled {
                Text("background_fetch_low_power_mode_warning")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }
    
    private var toggleIconName: String {
        isEnabled ? "arrow.clockwise.circle.fill" : "arrow.clockwise.circle"
    }
    
    private var toggleIconColor: Color {
        isEnabled ? Color.blue : .gray
    }
    
    @ViewBuilder
    private var intervalSettingsSection: some View {
        if isEnabled && !isLowPowerModeEnabled {
            Section {
                intervalSettingsContent
            } header: {
                Text("background_fetch_interval_settings")
            } footer: {
                Text("background_fetch_interval_footer")
                    .font(.caption)
            }
        }
    }
    
    private var intervalSettingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            intervalHeader
            intervalSlider
        }
        .padding(.vertical, 4)
    }
    
    private var intervalHeader: some View {
        HStack {
            Text("background_fetch_interval")
            Spacer()
            Text(BackgroundFetchConfig.formatInterval(intervalMinutes))
                .foregroundColor(.secondary)
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
                .font(.caption)
                .foregroundColor(.secondary)
        } maximumValueLabel: {
            Text("\(BackgroundFetchConfig.maxIntervalMinutes) min")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onChange(of: intervalMinutes) { _, newValue in
            handleIntervalChange(newValue)
        }
    }
    
    private var statusSection: some View {
        Section {
            statusHeader
            lastCheckRow
        } header: {
            Text("status")
        }
    }
    
    private var statusHeader: some View {
        HStack {
            Label {
                Text("background_fetch_status")
            } icon: {
                Image(systemName: statusIcon)
                    .foregroundColor(statusColor)
            }
            
            Spacer()
            
            Text(statusText)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var lastCheckRow: some View {
        if let lastFetch = fetchManager.lastFetchDate {
            HStack {
                Label {
                    Text("background_fetch_last_check")
                } icon: {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(formatLastCheckDate(lastFetch))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var lowPowerModeWarningSection: some View {
        if isLowPowerModeEnabled {
            Section {
                lowPowerModeWarningContent
            } header: {
                Text("background_fetch_energy_saving")
            }
        }
    }
    
    private var lowPowerModeWarningContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "battery.25")
                .foregroundColor(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("background_fetch_low_power_mode_title")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("background_fetch_low_power_mode_description")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Computed Properties
    
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
            return Color.AppStatus.success
        } else {
            return .gray
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
                .foregroundColor(current == minutes ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(current == minutes ? Color.blue : Color.gray.opacity(0.2))
                )
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BackgroundFetchSettingsView()
    }
}
