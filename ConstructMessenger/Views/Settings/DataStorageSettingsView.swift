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
        List {
            // MARK: Usage section
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("media_cache", systemImage: "photo.on.rectangle.angled")
                        Spacer()
                        Text(formatBytes(cacheSize))
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .monospacedDigit()
                    }

                    if maxDiskCacheBytesRaw > 0 {
                        let fraction = min(Double(cacheSize) / Double(maxDiskCacheBytesRaw), 1.0)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(fraction > 0.85 ? Color.orange : Color.accentColor)
                                    .frame(width: geo.size.width * fraction, height: 6)
                                    .animation(.easeInOut(duration: 0.4), value: fraction)
                            }
                        }
                        .frame(height: 6)

                        Text(String(format: NSLocalizedString("storage_of_quota", comment: ""),
                                    formatBytes(cacheSize), formatBytes(Int64(maxDiskCacheBytesRaw))))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    if isClearing {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text("storage_clearing")
                        }
                    } else {
                        Text("storage_clear_media_cache")
                    }
                }
                .disabled(isClearing || cacheSize == 0)
            } header: {
                Text("storage_media_cache")
            } footer: {
                Text("storage_media_cache_footer")
            }

            // MARK: Quota section
            Section {
                Picker("storage_limit", selection: $maxDiskCacheBytesRaw) {
                    ForEach(quotaOptions, id: \.bytes) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("storage_limit")
            } footer: {
                Text(maxDiskCacheBytesRaw == 0
                     ? "storage_no_limit_footer"
                     : "storage_limit_footer")
            }

            // MARK: Auto-eviction section
            Section {
                Picker("storage_auto_clear", selection: $evictAfterDays) {
                    ForEach(evictOptions, id: \.days) { option in
                        Text(option.label).tag(option.days)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("storage_auto_clear")
            } footer: {
                Text("storage_auto_clear_footer")
            }
        }
        .navigationTitle("data_and_storage")
        .navigationBarTitleDisplayMode(.inline)
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
}
#endif
