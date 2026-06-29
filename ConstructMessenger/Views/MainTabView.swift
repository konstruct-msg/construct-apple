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
            // Standard system tab bar. SwiftUI loads each tab's content lazily on
            // first selection, so there is no @FetchRequest burst at launch — the
            // reason the old ZStack/visitedTabs workaround existed no longer applies.
            // Tab values match the legacy indices: chats 0, synaps 1, calls 2
            // (when enabled), settings 3-or-2. The per-tab tab-bar hiding inside a
            // conversation lives on the ChatView navigation destination.
            TabView(selection: $vm.selectedTab) {
                Tab(value: 0) {
                    ChatsListView()
                        .environment(chatsViewModel)
                } label: {
                    Image(systemName: "message")
                }

                Tab(value: 1) {
                    SynapsView()
                        .environment(chatsViewModel)
                } label: {
                    Image(systemName: "circle.grid.cross")
                }

                if CallsFeature.isEnabled {
                    Tab(value: 2) {
                        CallHistoryView()
                    } label: {
                        Image(systemName: "phone")
                    }
                }

                Tab(value: settingsTab) {
                    SettingsView()
                        .environment(chatsViewModel)
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .tint(Color.CT.accent)
            .toolbarBackground(.hidden, for: .tabBar)
            .ctBackground()
        }
    }

    /// Settings tab value — shifts to 3 when the calls tab is present, else 2.
    private var settingsTab: Int { CallsFeature.isEnabled ? 3 : 2 }

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
struct InCallMiniBar: View {
    let peerName: String
    let isConnecting: Bool
    let onTap: () -> Void

    /// Approximate laid-out height (text + vertical padding). Used by views that must reserve
    /// space for the bar themselves because `.safeAreaInset` on the TabView does not propagate
    /// into pushed NavigationStack destinations (e.g. ChatView's floating nav capsule).
    static let barHeight: CGFloat = 30

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
