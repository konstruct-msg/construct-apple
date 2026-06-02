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
    @State private var callManager = CallManager.shared

    /// Tracks which tab indices have been visited at least once.
    /// A tab's content view is only inserted into the ZStack after its first visit,
    /// preventing @FetchRequest from firing for every tab simultaneously at launch.
    /// This was causing EXC_CRASH on iOS 26: _ZStackLayout.sizeThatFits triggers
    /// @FetchRequest.update on ALL ZStack children (even opacity=0 ones) during layout.
    @State private var visitedTabs: Set<Int> = [0]

    var body: some View {
        // Incoming-call UI on iOS is owned by CallKit (system banner / lock-screen
        // / dynamic-island). Drawing our own overlay duplicates it and the two
        // accept buttons go out of sync (our button bypassed CallKit, leaving
        // the system banner hanging). The custom sheet is preserved for non-iOS
        // platforms (where CallKit doesn't exist) in their own MainTab variant.
        callContent
            .debugMetricsOverlay()
            .fullScreenCover(isPresented: .constant(CallsFeature.isEnabled && isActiveOrConnecting)) {
                if let session = activeCallSession {
                    InCallView(session: session, isConnecting: isConnectingState, endReason: callEndReason)
                }
            }
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
            CTTabItem(symbol: CTSymbol.tabChats, sfName: "message"),
            CTTabItem(symbol: CTSymbol.tabSynaps, sfName: "circle.grid.cross"),
        ]
        if CallsFeature.isEnabled {
            items.append(CTTabItem(symbol: CTSymbol.tabCalls, sfName: "phone"))
        }
        items.append(CTTabItem(symbol: CTSymbol.tabSettings, sfName: "gearshape"))
        return items
    }

    // MARK: - Call state helpers

    private var isActiveOrConnecting: Bool {
        switch callManager.state {
        case .dialing, .active, .connecting, .ringing, .ended: return true
        default: return false
        }
    }

    private var isConnectingState: Bool {
        switch callManager.state {
        case .dialing, .connecting, .ringing: return true
        default: return false
        }
    }

    private var activeCallSession: CallManager.CallSession? {
        switch callManager.state {
        case .dialing(let s), .active(let s), .connecting(let s), .ringing(let s): return s
        case .ended(let s, _): return s
        default: return nil
        }
    }

    private var callEndReason: CallManager.EndReason? {
        if case .ended(_, let reason) = callManager.state { return reason }
        return nil
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