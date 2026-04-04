//
//  DataStorageSettingsView.swift
//  Construct Messenger
//
//  Data & Storage settings: media cache usage, quota, and auto-eviction.
//

import SwiftUI

struct DataStorageSettingsView: View {

    // MARK: - Persisted settings

    @AppStorage(MediaManager.maxDiskCacheBytesKey)
    private var maxDiskCacheBytesRaw: Int = MediaManager.defaultMaxDiskCacheBytes

    @AppStorage(MediaManager.evictAfterDaysKey)
    private var evictAfterDays: Int = 0

    // MARK: - View state

    @State private var cacheSize: Int64 = 0
    @State private var isClearing = false
    @State private var showClearConfirm = false

    // MARK: - Options

    private let quotaOptions: [(label: LocalizedStringKey, bytes: Int)] = [
        ("256 MB",  256 * 1024 * 1024),
        ("512 MB",  512 * 1024 * 1024),
        ("1 GB",    1_073_741_824),
        ("2 GB",    2_147_483_648),
        ("5 GB",    5_368_709_120),
        ("storage_no_limit", 0),
    ]

    private let evictOptions: [(label: LocalizedStringKey, days: Int)] = [
        ("storage_keep_forever", 0),
        ("storage_keep_7_days",  7),
        ("storage_keep_30_days", 30),
        ("storage_keep_90_days", 90),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {

                // MARK: - Usage section
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("storage_media_cache", comment: "").uppercased()) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("media_cache", systemImage: "photo.on.rectangle.angled")
                                    .font(CTFont.bold(16))
                                    .foregroundStyle(Color.CT.text)
                                Spacer()
                                Text(formatBytes(cacheSize))
                                    .foregroundStyle(Color.CT.textDim)
                                    .font(CTFont.regular(14))
                                    .monospacedDigit()
                            }
                            if maxDiskCacheBytesRaw > 0 {
                                let fraction = min(Double(cacheSize) / Double(maxDiskCacheBytesRaw), 1.0)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.CT.noise)
                                            .frame(height: 4)
                                        Rectangle()
                                            .fill(fraction > 0.85 ? Color.orange : Color.CT.accent)
                                            .frame(width: geo.size.width * fraction, height: 4)
                                            .animation(.easeInOut(duration: 0.4), value: fraction)
                                    }
                                }
                                .frame(height: 6)
                                Text(String(format: NSLocalizedString("storage_of_quota", comment: ""),
                                            formatBytes(cacheSize), formatBytes(Int64(maxDiskCacheBytesRaw))))
                                    .font(CTFont.regular(11))
                                    .foregroundStyle(Color.CT.textDim)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        ConstructRowDivider(indent: 16)

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
                    Text(LocalizedStringKey("storage_media_cache_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }

                // MARK: - Quota section
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("storage_limit", comment: "").uppercased()) {
                        Picker(LocalizedStringKey("storage_limit"), selection: $maxDiskCacheBytesRaw) {
                            ForEach(quotaOptions, id: \.bytes) { option in
                                Text(option.label).tag(option.bytes)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .tint(Color.CT.accent)
                    }
                    Text(LocalizedStringKey(maxDiskCacheBytesRaw == 0 ? "storage_no_limit_footer" : "storage_limit_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
                }

                // MARK: - Auto-eviction section
                VStack(alignment: .leading, spacing: 6) {
                    ConstructSection(header: NSLocalizedString("storage_auto_clear", comment: "").uppercased()) {
                        Picker(LocalizedStringKey("storage_auto_clear"), selection: $evictAfterDays) {
                            ForEach(evictOptions, id: \.days) { option in
                                Text(option.label).tag(option.days)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .tint(Color.CT.accent)
                    }
                    Text(LocalizedStringKey("storage_auto_clear_footer"))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 20)
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
                Text(NSLocalizedString("data_and_storage", comment: "").uppercased())
                    .font(CTFont.bold(13))
                    .foregroundStyle(Color.CT.text)
                    .tracking(4)
            }
        }
        .task { cacheSize = MediaManager.shared.diskCacheSize() }
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

    private func clearCache() async {
        isClearing = true
        MediaManager.shared.clearCache(includingDisk: true)
        cacheSize = MediaManager.shared.diskCacheSize()
        isClearing = false
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
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
