//
//  BackgroundFetchSettingsView.swift
//  Construct Messenger
//
//  Created by Auto on 03.01.2026.
//

import SwiftUI

struct BackgroundFetchSettingsView: View {
    private static let lastCheckFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: - State
    @Environment(\.dismiss) private var dismiss
    @AppStorage("backgroundFetchEnabled") private var isEnabled: Bool = true
    @State private var intervalMinutes: Int = BackgroundFetchConfig.defaultIntervalMinutes
    @State private var isLowPowerModeEnabled: Bool = false
    @State private var showingLowPowerModeAlert = false
    private let fetchManager = BackgroundFetchManager.shared

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("background_fetch", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            )
            ScrollView {
                LazyVStack(spacing: 0) {

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
                                VStack(alignment: .leading, spacing: BackgroundFetchSettingsLayout.warningSpacing) {
                                    Text(LocalizedStringKey("enable_background_fetch"))
                                        .font(CTFont.regular(13))
                                        .foregroundColor(
                                            isLowPowerModeEnabled
                                            ? Color.CT.textDim.opacity(BackgroundFetchSettingsLayout.disabledRowOpacity)
                                            : Color.CT.text
                                        )
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
                            .padding(.horizontal, BackgroundFetchSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, BackgroundFetchSettingsLayout.rowVerticalPadding)
                        }
                        .buttonStyle(.plain)
                    }

                    sectionFooter("background_fetch_footer")

                    // MARK: - Interval Settings section
                    if isEnabled && !isLowPowerModeEnabled {
                        CTSettingsSectionHeader(title: NSLocalizedString("background_fetch_interval_settings", comment: "").uppercased())
                        CTSectionGroup {
                            VStack(alignment: .leading, spacing: BackgroundFetchSettingsLayout.intervalSectionSpacing) {
                                intervalHeader
                                intervalStepper
                            }
                            .padding(.horizontal, BackgroundFetchSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, BackgroundFetchSettingsLayout.rowVerticalPadding)
                        }
                        sectionFooter("background_fetch_interval_footer")
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
                        .padding(.horizontal, BackgroundFetchSettingsLayout.rowHorizontalPadding)
                        .padding(.vertical, BackgroundFetchSettingsLayout.rowVerticalPadding)

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
                            .padding(.horizontal, BackgroundFetchSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, BackgroundFetchSettingsLayout.rowVerticalPadding)
                        }
                    }

                    // MARK: - Low Power Mode Warning section
                    if isLowPowerModeEnabled {
                        CTSettingsSectionHeader(title: NSLocalizedString("background_fetch_energy_saving", comment: "").uppercased())
                        CTSectionGroup {
                            VStack(alignment: .leading, spacing: BackgroundFetchSettingsLayout.warningSpacing) {
                                Text(LocalizedStringKey("background_fetch_low_power_mode_title"))
                                    .font(CTFont.regular(13))
                                    .foregroundColor(Color.CT.textDim)
                                Text(LocalizedStringKey("background_fetch_low_power_mode_description"))
                                    .font(CTFont.regular(11))
                                    .foregroundColor(Color.CT.textDim)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, BackgroundFetchSettingsLayout.rowHorizontalPadding)
                            .padding(.vertical, BackgroundFetchSettingsLayout.rowVerticalPadding)
                        }
                    }
                }
                .padding(.vertical, BackgroundFetchSettingsLayout.sectionVerticalPadding)
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
                let newVal = max(
                    BackgroundFetchConfig.minIntervalMinutes,
                    intervalMinutes - BackgroundFetchSettingsConfig.intervalStepMinutes
                )
                if newVal != intervalMinutes {
                    intervalMinutes = newVal
                    handleIntervalChange(newVal)
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: BackgroundFetchSettingsLayout.stepperButtonFontSize, weight: .bold))
                    .foregroundColor(intervalMinutes > BackgroundFetchConfig.minIntervalMinutes ? Color.CT.accent : Color.CT.textDim)
                    .frame(
                        width: BackgroundFetchSettingsLayout.stepperButtonWidth,
                        height: BackgroundFetchSettingsLayout.stepperButtonHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.CT.noise)
                .frame(
                    width: BackgroundFetchSettingsLayout.stepperDividerWidth,
                    height: BackgroundFetchSettingsLayout.stepperDividerHeight
                )

            Spacer()

            // Preset chips: 5 · 15 · 30 · 60
            HStack(spacing: BackgroundFetchSettingsLayout.presetSpacing) {
                ForEach(BackgroundFetchSettingsConfig.intervalPresets, id: \.self) { preset in
                    Button {
                        intervalMinutes = preset
                        handleIntervalChange(preset)
                    } label: {
                        Text("\(preset)")
                            .font(CTFont.regular(11))
                            .foregroundColor(intervalMinutes == preset ? Color.CT.accent : Color.CT.textDim)
                            .padding(.horizontal, BackgroundFetchSettingsLayout.presetHorizontalPadding)
                            .padding(.vertical, BackgroundFetchSettingsLayout.presetVerticalPadding)
                            .overlay(
                                Rectangle()
                                    .stroke(
                                        intervalMinutes == preset ? Color.CT.accent : Color.CT.noise,
                                        lineWidth: BackgroundFetchSettingsLayout.presetStrokeWidth
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Rectangle()
                .fill(Color.CT.noise)
                .frame(
                    width: BackgroundFetchSettingsLayout.stepperDividerWidth,
                    height: BackgroundFetchSettingsLayout.stepperDividerHeight
                )

            Button {
                let newVal = min(
                    BackgroundFetchConfig.maxIntervalMinutes,
                    intervalMinutes + BackgroundFetchSettingsConfig.intervalStepMinutes
                )
                if newVal != intervalMinutes {
                    intervalMinutes = newVal
                    handleIntervalChange(newVal)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: BackgroundFetchSettingsLayout.stepperButtonFontSize, weight: .bold))
                    .foregroundColor(intervalMinutes < BackgroundFetchConfig.maxIntervalMinutes ? Color.CT.accent : Color.CT.textDim)
                    .frame(
                        width: BackgroundFetchSettingsLayout.stepperButtonWidth,
                        height: BackgroundFetchSettingsLayout.stepperButtonHeight
                    )
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
        Self.lastCheckFormatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func sectionFooter(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(CTFont.regular(11))
            .foregroundStyle(Color.CT.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BackgroundFetchSettingsLayout.rowHorizontalPadding)
            .padding(.bottom, BackgroundFetchSettingsLayout.footerBottomPadding)
    }
}

// MARK: - Preview

#Preview {
    BackgroundFetchSettingsView()
        .preferredColorScheme(.dark)
}
