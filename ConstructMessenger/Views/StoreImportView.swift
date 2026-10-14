//
//  StoreImportView.swift
//  Construct Messenger
//
//  The first launch after the update that moves iOS to `construct.db` (LOCAL_STORE_MIGRATION_PLAN
//  step 4): the app is this screen until the copy is done — no network, nothing else writing.
//  Decided with the owner 2026-10-14 over a copy in the background, which would have had to
//  carry over whatever arrived while it ran.
//

import SwiftUI

struct StoreImportView: View {
    /// Called once, on the main actor, whether the import succeeded or not: the app goes on
    /// either way — on the new store, or on Core Data with a retry at the next launch.
    let onDone: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var progress = 0.0
    @State private var started = false

    var body: some View {
        VStack(spacing: CTLayout.sectionGap) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(CTFont.ui(40, weight: .light))
                .foregroundStyle(Color.CT.textDim)
                .accessibilityHidden(true)
            VStack(spacing: CTLayout.chromeGap) {
                Text(LocalizedStringKey("store_import_title"))
                    .font(CTFont.headline)
                    .foregroundStyle(Color.CT.text)
                    .multilineTextAlignment(.center)
                Text(LocalizedStringKey("store_import_body"))
                    .font(CTFont.secondary)
                    .foregroundStyle(Color.CT.textDim)
                    .multilineTextAlignment(.center)
            }
            ProgressView(value: progress)
                .tint(Color.CT.accent)
                .frame(maxWidth: 240)
            Spacer()
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ctBackground()
        // Only on screen: a launch iOS made in the background shows nothing, has little time,
        // and is not where a whole transcript should be copied.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, !started else { return }
            started = true
            Task.detached(priority: .userInitiated) {
                do {
                    let counts = try LocalRepositories.importFromCoreData(
                        ownAccountId: AuthSessionManager.shared.currentUserId
                    ) { value in
                        Task { @MainActor in progress = value }
                    }
                    Log.info("StoreImport: done — \(counts)", category: "Storage")
                } catch {
                    Log.error("StoreImport: failed, staying on Core Data until the next launch — \(error)", category: "Storage")
                }
                await MainActor.run { onDone() }
            }
        }
    }
}
