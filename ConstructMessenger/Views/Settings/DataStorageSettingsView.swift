//
//  DataStorageSettingsView.swift
//  Construct Messenger
//
//  Data & Storage settings: media cache usage, quota, and auto-eviction.
//

import SwiftUI

struct DataStorageSettingsView: View {
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    var showNavBar: Bool = true

    // MARK: - Persisted settings

    @AppStorage(MediaManager.maxDiskCacheBytesKey)
    private var maxDiskCacheBytesRaw: Int = MediaManager.defaultMaxDiskCacheBytes

    @AppStorage(MediaManager.evictAfterDaysKey)
    private var evictAfterDays: Int = 0

    

    // MARK: - View state

    @State private var cacheSize: Int64 = 0
    @State private var isClearing = false
    @State private var showClearConfirm = false
    @State private var quotaSliderIndex: Double = 0
    @State private var hasLoadedInitialCacheState = false

    @Environment(\.dismiss) private var dismiss

    // MARK: - Options

    private let quotaOptions: [(label: String, bytes: Int)] = [
        ("256 MB",  DataStorageSettingsConfig.quarterGBInBytes),
        ("512 MB",  DataStorageSettingsConfig.halfGBInBytes),
        ("1 GB",    DataStorageSettingsConfig.oneGBInBytes),
        ("2 GB",    DataStorageSettingsConfig.twoGBInBytes),
        ("5 GB",    DataStorageSettingsConfig.fiveGBInBytes),
        (NSLocalizedString("storage_no_limit", comment: ""), 0),
    ]

    private let evictOptions: [(label: String, days: Int)] = [
        (NSLocalizedString("storage_keep_forever", comment: ""), 0),
        (NSLocalizedString("storage_keep_7_days", comment: ""),  DataStorageSettingsConfig.evictAfterOneWeekDays),
        (NSLocalizedString("storage_keep_30_days", comment: ""), DataStorageSettingsConfig.evictAfterOneMonthDays),
        (NSLocalizedString("storage_keep_90_days", comment: ""), DataStorageSettingsConfig.evictAfterThreeMonthsDays),
    ]

    private var currentQuotaLabel: String {
        quotaOptions[selectedQuotaIndex].label
    }
    private var selectedQuotaIndex: Int {
        Int(quotaSliderIndex.rounded())
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if showNavBar {
                    CTNavBar(
                        title: NSLocalizedString("data_and_storage", comment: ""),
                        showBack: true,
                        backAction: { dismiss() }
                    ) {
                        EmptyView()
                    } trailing: {
                        EmptyView()
                    }
                }

                VStack(spacing: 0) {

                    // MARK: Usage
                    CTSettingsSectionHeader(title: NSLocalizedString("storage_media_cache", comment: ""))
                    CTSectionGroup {
                        // Usage row
                        HStack(spacing: DataStorageSettingsLayout.rowContentSpacing) {
                            Image(systemName: "internaldrive")
                                .font(CTFont.regular(DataStorageSettingsLayout.usageIconFontSize))
                                .foregroundStyle(Color.CT.textDim)
                                .frame(width: SettingsLayout.rowIconMinWidth)
                            Text(NSLocalizedString("storage_media_cache", comment: "").uppercased())
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.text)
                                .tracking(DataStorageSettingsLayout.sectionTitleTracking)
                            Spacer()
                            Text(formatBytes(cacheSize))
                                .font(CTFont.bold(14))
                                .foregroundStyle(cacheSize > 0 ? Color.CT.accent : Color.CT.textDim)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, DataStorageSettingsLayout.rowHorizontalPadding)
                        .padding(.top, DataStorageSettingsLayout.usageRowTopPadding)
                        .padding(
                            .bottom,
                            maxDiskCacheBytesRaw > 0
                            ? DataStorageSettingsLayout.usageRowBottomPaddingWithQuota
                            : DataStorageSettingsLayout.usageRowBottomPaddingWithoutQuota
                        )

                        // Storage bar (only when quota is set)
                        if maxDiskCacheBytesRaw > 0 {
                            let fraction = min(Double(cacheSize) / Double(maxDiskCacheBytesRaw), 1.0)
                            VStack(alignment: .leading, spacing: DataStorageSettingsLayout.usageBarSpacing) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.CT.noise)
                                            .frame(height: DataStorageSettingsLayout.usageBarHeight)
                                        Rectangle()
                                            .fill(
                                                fraction > DataStorageSettingsConfig.usageWarningThreshold
                                                ? Color.orange
                                                : Color.CT.accent
                                            )
                                            .frame(
                                                width: geo.size.width * fraction,
                                                height: DataStorageSettingsLayout.usageBarHeight
                                            )
                                            .animation(
                                                .easeInOut(duration: DataStorageSettingsLayout.usageFractionAnimationDuration),
                                                value: fraction
                                            )
                                    }
                                }
                                .frame(height: DataStorageSettingsLayout.usageBarHeight)
                                Text(String(format: NSLocalizedString("storage_of_quota", comment: ""),
                                            formatBytes(cacheSize), formatBytes(Int64(maxDiskCacheBytesRaw))))
                                    .font(CTFont.regular(10))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                            .padding(.horizontal, DataStorageSettingsLayout.rowHorizontalPadding)
                            .padding(.bottom, DataStorageSettingsLayout.usageRowBottomPaddingWithoutQuota)
                        }

                        CTSep(style: .thin)

                        ConstructActionRow(
                            systemImage: "trash",
                            title: isClearing
                                ? LocalizedStringKey("storage_clearing")
                                : LocalizedStringKey("storage_clear_media_cache"),
                            role: .destructive,
                            isLoading: isClearing
                        ) {
                            showClearConfirm = true
                        }
                        .disabled(isClearing || cacheSize == 0)
                        .opacity(
                            (isClearing || cacheSize == 0)
                            ? DataStorageSettingsLayout.clearActionDisabledOpacity
                            : 1
                        )
                    }
                    sectionFooter("storage_media_cache_footer")

                    // MARK: Storage Limit
                    CTSettingsSectionHeader(title: NSLocalizedString("storage_limit", comment: ""))
                    CTSectionGroup {
                        VStack(alignment: .leading, spacing: DataStorageSettingsLayout.quotaSectionSpacing) {
                            HStack {
                                Text(NSLocalizedString("storage_limit", comment: "").uppercased())
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.textDim)
                                    .tracking(DataStorageSettingsLayout.sectionTitleTracking)
                                Spacer()
                                Text(currentQuotaLabel)
                                    .font(CTFont.bold(14))
                                    .foregroundStyle(Color.CT.accent)
                            }

                            Slider(
                                value: $quotaSliderIndex,
                                in: 0...Double(quotaOptions.count - 1),
                                step: 1
                            )
                            .tint(Color.CT.accent)
                            .onChange(of: quotaSliderIndex) { _, idx in
                                maxDiskCacheBytesRaw = quotaOptions[Int(idx.rounded())].bytes
                            }

                            // Tick labels under the slider
                            let quotas = quotaOptions
                            HStack(spacing: 0) {
                                ForEach(Array(quotas.enumerated()), id: \.offset) { pair in
                                    let i = pair.offset
                                    Text(pair.element.label)
                                        .font(CTFont.regular(DataStorageSettingsLayout.quotaTickFontSize))
                                        .foregroundStyle(
                                            selectedQuotaIndex == i
                                                ? Color.CT.accent : Color.CT.textDim
                                        )
                                        .frame(maxWidth: .infinity)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(1)
                                        .minimumScaleFactor(DataStorageSettingsLayout.quotaTickMinimumScale)
                                }
                            }
                        }
                        .padding(.horizontal, DataStorageSettingsLayout.rowHorizontalPadding)
                        .padding(.vertical, SettingsLayout.rowVerticalPadding)
                    }
                    sectionFooter(maxDiskCacheBytesRaw == 0 ? "storage_no_limit_footer" : "storage_limit_footer")

                    // MARK: Auto-eviction
                    CTSettingsSectionHeader(title: NSLocalizedString("storage_auto_clear", comment: ""))
                    CTSectionGroup {
                        let evicts = evictOptions
                        ForEach(Array(evicts.enumerated()), id: \.offset) { pair in
                            let i = pair.offset
                            if i > 0 { CTSep(style: .thin) }
                            Button {
                                evictAfterDays = pair.element.days
                            } label: {
                                HStack(spacing: DataStorageSettingsLayout.rowContentSpacing) {
                                    Image(systemName: evictAfterDays == pair.element.days
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(CTFont.regular(DataStorageSettingsLayout.autoEvictionCheckIconSize))
                                        .foregroundStyle(
                                            evictAfterDays == pair.element.days
                                                ? Color.CT.accent : Color.CT.textDim
                                        )
                                        .frame(width: SettingsLayout.rowIconMinWidth)
                                    Text(pair.element.label.uppercased())
                                        .font(CTFont.regular(13))
                                        .foregroundStyle(Color.CT.text)
                                        .tracking(DataStorageSettingsLayout.sectionTitleTracking)
                                    Spacer()
                                }
                                .padding(.horizontal, DataStorageSettingsLayout.rowHorizontalPadding)
                                .padding(.vertical, DataStorageSettingsLayout.usageRowTopPadding)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    sectionFooter("storage_auto_clear_footer")

                   
                }
                .padding(.bottom, DataStorageSettingsLayout.screenBottomPadding)
            }
        }
        .background(Color.CT.bg.ignoresSafeArea())
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            guard !hasLoadedInitialCacheState else { return }
            hasLoadedInitialCacheState = true
            cacheSize = MediaManager.shared.diskCacheSize()
            quotaSliderIndex = Double(
                quotaOptions.firstIndex(where: { $0.bytes == maxDiskCacheBytesRaw })
                    ?? (quotaOptions.count - 1)
            )
        }
        .confirmationDialog("storage_clear_confirm_title",
                            isPresented: $showClearConfirm,
                            titleVisibility: .visible) {
            Button("storage_clear_media_cache", role: .destructive) {
                Task { await clearCache() }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("storage_clear_confirm_message")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionFooter(_ key: String) -> some View {
        Text(LocalizedStringKey(key))
            .font(CTFont.regular(11))
            .foregroundStyle(Color.CT.textDim)
            .padding(.horizontal, SettingsLayout.footerHorizontalPadding)
            .padding(.top, DataStorageSettingsLayout.footerTopPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearCache() async {
        isClearing = true
        MediaManager.shared.clearCache(includingDisk: true)
        cacheSize = MediaManager.shared.diskCacheSize()
        isClearing = false
    }

    private func formatBytes(_ bytes: Int64) -> String {
        Self.byteCountFormatter.string(fromByteCount: bytes)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        DataStorageSettingsView()
    }
    .preferredColorScheme(.dark)
}
#endif
