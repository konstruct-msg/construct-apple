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
    @State private var fetchManager = BackgroundFetchManager.shared

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
                        HStack(spacing: BackgroundFetchSettingsLayout.toggleRowSpacing) {
                            Text(LocalizedStringKey("enable_background_fetch"))
                                .font(CTFont.regular(13))
                                .foregroundColor(
                                    isLowPowerModeEnabled
                                    ? Color.CT.textDim.opacity(BackgroundFetchSettingsLayout.disabledRowOpacity)
                                    : Color.CT.text
                                )
                            Spacer(minLength: 0)
                            Toggle("", isOn: $isEnabled)
                                .labelsHidden()
                                .tint(Color.CT.accent)
                        }
                        .padding(.horizontal, BackgroundFetchSettingsLayout.rowHorizontalPadding)
                        .padding(.vertical, BackgroundFetchSettingsLayout.rowVerticalPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(isLowPowerModeEnabled)
                    }
                    .onChange(of: isEnabled) { _, newValue in
                        handleToggleChange(newValue)
                    }

                    sectionFooter("background_fetch_footer")

                    // MARK: - Interval Settings section
                    if isEnabled && !isLowPowerModeEnabled {
                        CTSettingsSectionHeader(title: NSLocalizedString("background_fetch_interval_settings", comment: "").uppercased())
                        CTSectionGroup {
                            VStack(alignment: .leading, spacing: BackgroundFetchSettingsLayout.sliderSectionSpacing) {
                                intervalHeader
                                intervalSlider
                                intervalTrackMarks
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

    private var intervalSlider: some View {
        Slider(
            value: intervalMinutesBinding,
            in: Double(BackgroundFetchConfig.minIntervalMinutes)...Double(BackgroundFetchConfig.maxIntervalMinutes),
            step: Double(BackgroundFetchSettingsConfig.intervalStepMinutes)
        )
        .tint(Color.CT.accent)
        .accessibilityLabel(Text(NSLocalizedString("background_fetch_interval", comment: "")))
    }

    private var intervalTrackMarks: some View {
        HStack(spacing: 0) {
            ForEach(intervalTickValues, id: \.self) { value in
                VStack(spacing: BackgroundFetchSettingsLayout.trackMarkSpacing) {
                    Rectangle()
                        .fill(value == intervalMinutes ? Color.CT.accent : Color.CT.noise)
                        .frame(
                            width: BackgroundFetchSettingsLayout.trackMarkWidth,
                            height: value == intervalMinutes
                                ? BackgroundFetchSettingsLayout.trackMajorMarkHeight
                                : BackgroundFetchSettingsLayout.trackMinorMarkHeight
                        )
                    if BackgroundFetchSettingsConfig.intervalPresets.contains(value) {
                        Text(BackgroundFetchConfig.formatInterval(value))
                            .font(CTFont.regular(BackgroundFetchSettingsLayout.tickLabelFontSize))
                            .foregroundStyle(value == intervalMinutes ? Color.CT.accent : Color.CT.textDim)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(BackgroundFetchSettingsLayout.tickLabelMinimumScale)
                    } else {
                        Text(" ")
                            .font(CTFont.regular(BackgroundFetchSettingsLayout.tickLabelFontSize))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var intervalTickValues: [Int] {
        Array(stride(
            from: BackgroundFetchConfig.minIntervalMinutes,
            through: BackgroundFetchConfig.maxIntervalMinutes,
            by: BackgroundFetchSettingsConfig.intervalStepMinutes
        ))
    }

    private var intervalMinutesBinding: Binding<Double> {
        Binding(
            get: { Double(intervalMinutes) },
            set: { newValue in
                updateIntervalMinutes(Int(newValue.rounded()))
            }
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

    private func updateIntervalMinutes(_ newValue: Int) {
        let clampedValue = max(
            BackgroundFetchConfig.minIntervalMinutes,
            min(BackgroundFetchConfig.maxIntervalMinutes, newValue)
        )
        guard clampedValue != intervalMinutes else { return }
        intervalMinutes = clampedValue
        handleIntervalChange(clampedValue)
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
