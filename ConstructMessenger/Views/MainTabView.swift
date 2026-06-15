//
//  MainTabView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

#if os(iOS)
import SwiftUI
import CoreData

struct MainTabView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel

    /// Compact = iPhone (or iPad in narrow split-screen multitasking)
    /// Regular = iPad full-screen or landscape
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Call overlays
    @State private var callManager: (any CallUIManaging)? = CallRuntimeProvider.makeUIManager()

    /// Tracks which tab indices have been visited at least once.
    /// A tab's content view is only inserted into the ZStack after its first visit,
    /// preventing @FetchRequest from firing for every tab simultaneously at launch.
    /// This was causing EXC_CRASH on iOS 26: _ZStackLayout.sizeThatFits triggers
    /// @FetchRequest.update on ALL ZStack children (even opacity=0 ones) during layout.
    @State private var visitedTabs: Set<Int> = [0]

    /// True when the in-call full-screen cover should be shown; false when the
    /// user has minimised the call to the top-of-screen mini bar. Persists across
    /// tab switches; reset to `true` whenever a new call begins.
    @State private var isCallExpanded: Bool = true

    var body: some View {
        // Incoming-call UI on iOS is owned by CallKit (system banner / lock-screen
        // / dynamic-island). Drawing our own overlay duplicates it and the two
        // accept buttons go out of sync (our button bypassed CallKit, leaving
        // the system banner hanging). The custom sheet is preserved for non-iOS
        // platforms (where CallKit doesn't exist) in their own MainTab variant.
        callContent
            .debugMetricsOverlay()
            .safeAreaInset(edge: .top, spacing: 0) {
                if CallsFeature.isEnabled, isActiveOrConnecting, !isCallExpanded,
                   let session = activeCallSession {
                    InCallMiniBar(
                        peerName: session.peerName,
                        isConnecting: isConnectingState,
                        onTap: { isCallExpanded = true }
                    )
                }
            }
            .fullScreenCover(isPresented: fullScreenCoverBinding) {
                if let session = activeCallSession {
                    InCallView(
                        session: session,
                        isConnecting: isConnectingState,
                        endReason: callEndReason,
                        quality: callManager?.callQuality ?? .good,
                        onEnd: { callManager?.endCall() },
                        onMuteChanged: { muted in callManager?.setMuted(muted) },
                        onMinimize: { isCallExpanded = false }
                    )
                }
            }
            .onChange(of: isActiveOrConnecting) { _, isActive in
                // New call begins → restore full-screen even if the previous call
                // ended in the minimised state.
                if isActive { isCallExpanded = true }
            }
    }

    /// Binding that drives `fullScreenCover`. The cover is shown when there is
    /// a live call AND the user hasn't minimised it. The setter handles
    /// SwiftUI's own dismiss path (e.g. interactive swipe-down) by treating it
    /// as a minimise request — the call itself stays alive on `CallManager`.
    private var fullScreenCoverBinding: Binding<Bool> {
        Binding(
            get: { CallsFeature.isEnabled && callManager != nil && isActiveOrConnecting && isCallExpanded },
            set: { newValue in
                if !newValue { isCallExpanded = false }
            }
        )
    }

    @ViewBuilder
    private var callContent: some View {
        if horizontalSizeClass == .regular {
            ChatsSplitView()
                .environment(chatsViewModel)
        } else {
            @Bindable var vm = chatsViewModel
            VStack(spacing: 0) {
                tabContent(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !vm.isInChat && !vm.isInSettings {
                    CTTabBar(selected: $vm.selectedTab, items: tabItems)
                        .background(Color.CT.bg)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.isInChat || vm.isInSettings)
            .ctBackground()
        }
    }

    /// Renders tab views lazily: a tab's content is inserted into the ZStack only after
    /// it is first selected. Once mounted it stays alive (preserving scroll/nav state).
    /// Only tab 0 (ChatsListView) is rendered at startup to avoid @FetchRequest bursts.
    @ViewBuilder
    private func tabContent(vm: ChatsViewModel) -> some View {
        ZStack {
            // Tab 0: always rendered (initial tab).
            ChatsListView()
                .environment(chatsViewModel)
                .opacity(vm.selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(vm.selectedTab == 0)

            // Tab 1–N: mounted only after first visit.
            if visitedTabs.contains(1) {
                SynapsView()
                    .environment(chatsViewModel)
                    .opacity(vm.selectedTab == 1 ? 1 : 0)
                    .allowsHitTesting(vm.selectedTab == 1)
            }

            if CallsFeature.isEnabled, visitedTabs.contains(2) {
                CallHistoryView()
                    .opacity(vm.selectedTab == 2 ? 1 : 0)
                    .allowsHitTesting(vm.selectedTab == 2)
            }

            let settingsTab = CallsFeature.isEnabled ? 3 : 2
            if visitedTabs.contains(settingsTab) {
                SettingsView()
                    .environment(chatsViewModel)
                    .opacity(vm.selectedTab == settingsTab ? 1 : 0)
                    .allowsHitTesting(vm.selectedTab == settingsTab)
            }
        }
        .onChange(of: vm.selectedTab) { _, newTab in
            visitedTabs.insert(newTab)
        }
    }

    private var tabItems: [CTTabItem] {
        var items: [CTTabItem] = [
            CTTabItem(sfName: "message"),
            CTTabItem(sfName: "circle.grid.cross"),
        ]
        if CallsFeature.isEnabled {
            items.append(CTTabItem(sfName: "phone"))
        }
        items.append(CTTabItem(sfName: "gearshape"))
        return items
    }

    // MARK: - Call state helpers

    private var isActiveOrConnecting: Bool {
        guard let callManager else { return false }
        switch callManager.state {
        case .dialing, .active, .connecting, .ringing, .ended: return true
        default: return false
        }
    }

    private var isConnectingState: Bool {
        guard let callManager else { return false }
        switch callManager.state {
        case .dialing, .connecting, .ringing: return true
        default: return false
        }
    }

    private var activeCallSession: CallSession? {
        guard let callManager else { return nil }
        switch callManager.state {
        case .dialing(let s), .active(let s), .connecting(let s), .ringing(let s): return s
        case .ended(let s, _): return s
        default: return nil
        }
    }

    private var callEndReason: CallEndReason? {
        guard let callManager else { return nil }
        if case .ended(_, let reason) = callManager.state { return reason }
        return nil
    }
}

// MARK: - In-call mini bar

/// Top-of-screen pill shown while a call is live and the user has minimised
/// the full-screen `InCallView`. Tap restores full-screen. Mirrors the iOS
/// system in-call indicator pattern: thin, accent-coloured, single tap area.
private struct InCallMiniBar: View {
    let peerName: String
    let isConnecting: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.CT.bg)
                Text("> \(peerName)")
                    .font(CTFont.bold(12))
                    .foregroundStyle(Color.CT.bg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(NSLocalizedString(
                    isConnecting ? "call_minibar_connecting" : "call_minibar_in_call",
                    comment: ""
                ))
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.bg.opacity(0.75))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.CT.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("call_minibar_in_call", comment: ""))
    }
}

#if DEBUG
/// Retains the Core Data container for the lifetime of the preview process.
/// Using a class ensures ARC keeps the container alive even after the #Preview closure returns.
@MainActor
private final class MainTabPreviewState {
    static let shared = MainTabPreviewState()
    let container = PersistenceController(inMemory: true).container
    let authViewModel: AuthViewModel
    let chatsViewModel: ChatsViewModel

    private init() {
        let context = container.viewContext
        authViewModel = AuthViewModel(context: context)
        authViewModel.configureMockAuth()
        chatsViewModel = ChatsViewModel()
        chatsViewModel.setContext(context)

        let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
        let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
        _ = PreviewHelpers.createSampleChat(context: context, with: user1)
        _ = PreviewHelpers.createSampleChat(context: context, with: user2)
        try? context.save()
    }
}

#Preview {
    let state = MainTabPreviewState.shared
    return MainTabView()
        .environment(\.managedObjectContext, state.container.viewContext)
        .environment(state.authViewModel)
        .environment(state.chatsViewModel)
        .environment(SecurityViewModel())
}
#endif

#endif
