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
        ("256 MB",  256 * 1024 * 1024),
        ("512 MB",  512 * 1024 * 1024),
        ("1 GB",    1_073_741_824),
        ("2 GB",    2_147_483_648),
        ("5 GB",    5_368_709_120),
        (NSLocalizedString("storage_no_limit", comment: ""), 0),
    ]

    private let evictOptions: [(label: String, days: Int)] = [
        (NSLocalizedString("storage_keep_forever", comment: ""), 0),
        (NSLocalizedString("storage_keep_7_days", comment: ""),  7),
        (NSLocalizedString("storage_keep_30_days", comment: ""), 30),
        (NSLocalizedString("storage_keep_90_days", comment: ""), 90),
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
                    )
                }

                VStack(spacing: 0) {

                    // MARK: Usage
                    CTSettingsSectionHeader(title: NSLocalizedString("storage_media_cache", comment: ""))
                    CTSectionGroup {
                        // Usage row
                        HStack(spacing: 12) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.CT.textDim)
                                .frame(width: 22)
                            Text(NSLocalizedString("storage_media_cache", comment: "").uppercased())
                                .font(CTFont.regular(13))
                                .foregroundStyle(Color.CT.text)
                                .tracking(1)
                            Spacer()
                            Text(formatBytes(cacheSize))
                                .font(CTFont.bold(14))
                                .foregroundStyle(cacheSize > 0 ? Color.CT.accent : Color.CT.textDim)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 13)
                        .padding(.bottom, maxDiskCacheBytesRaw > 0 ? 10 : 13)

                        // Storage bar (only when quota is set)
                        if maxDiskCacheBytesRaw > 0 {
                            let fraction = min(Double(cacheSize) / Double(maxDiskCacheBytesRaw), 1.0)
                            VStack(alignment: .leading, spacing: 5) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.CT.noise)
                                            .frame(height: 5)
                                        Rectangle()
                                            .fill(fraction > 0.85 ? Color.orange : Color.CT.accent)
                                            .frame(width: geo.size.width * fraction, height: 5)
                                            .animation(.easeInOut(duration: 0.4), value: fraction)
                                    }
                                }
                                .frame(height: 5)
                                Text(String(format: NSLocalizedString("storage_of_quota", comment: ""),
                                            formatBytes(cacheSize), formatBytes(Int64(maxDiskCacheBytesRaw))))
                                    .font(CTFont.regular(10))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 13)
                        }

                        CTSep(style: .thin)

                        ConstructActionRow(
                            icon: "trash",
                            title: isClearing
                                ? LocalizedStringKey("storage_clearing")
                                : LocalizedStringKey("storage_clear_media_cache"),
                            role: .destructive,
                            isLoading: isClearing
                        ) {
                            showClearConfirm = true
                        }
                        .disabled(isClearing || cacheSize == 0)
                        .opacity((isClearing || cacheSize == 0) ? 0.5 : 1.0)
                    }
                    sectionFooter("storage_media_cache_footer")

                    // MARK: Storage Limit
                    CTSettingsSectionHeader(title: NSLocalizedString("storage_limit", comment: ""))
                    CTSectionGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(NSLocalizedString("storage_limit", comment: "").uppercased())
                                    .font(CTFont.regular(13))
                                    .foregroundStyle(Color.CT.textDim)
                                    .tracking(1)
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
                            HStack(spacing: 0) {
                                ForEach(quotaOptions.indices, id: \.self) { i in
                                    Text(quotaOptions[i].label)
                                        .font(CTFont.regular(9))
                                        .foregroundStyle(
                                            selectedQuotaIndex == i
                                                ? Color.CT.accent : Color.CT.textDim
                                        )
                                        .frame(maxWidth: .infinity)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    sectionFooter(maxDiskCacheBytesRaw == 0 ? "storage_no_limit_footer" : "storage_limit_footer")

                    // MARK: Auto-eviction
                    CTSettingsSectionHeader(title: NSLocalizedString("storage_auto_clear", comment: ""))
                    CTSectionGroup {
                        ForEach(evictOptions.indices, id: \.self) { i in
                            if i > 0 { CTSep(style: .thin) }
                            Button {
                                evictAfterDays = evictOptions[i].days
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: evictAfterDays == evictOptions[i].days
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 17))
                                        .foregroundStyle(
                                            evictAfterDays == evictOptions[i].days
                                                ? Color.CT.accent : Color.CT.textDim
                                        )
                                        .frame(width: 22)
                                    Text(evictOptions[i].label.uppercased())
                                        .font(CTFont.regular(13))
                                        .foregroundStyle(Color.CT.text)
                                        .tracking(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    sectionFooter("storage_auto_clear_footer")
                }
                .padding(.bottom, 32)
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
            .padding(.horizontal, 20)
            .padding(.top, 6)
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
