//
//  MainTabView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import SwiftUI
import CoreData

/// iOS 26 fix: wraps a tab's content so its body (and any @FetchRequest inside)
/// is only constructed after the tab appears for the first time.
/// Without this, iOS 26 TabView eagerly calls each child's body during layout,
/// triggering @FetchRequest before managedObjectContext is in the environment.
private struct LazyTabContent<Content: View>: View {
    @State private var hasAppeared = false
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Group {
            if hasAppeared {
                content()
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { hasAppeared = true }
            }
        }
    }
}

struct MainTabView: View {
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(ChatsViewModel.self) private var chatsViewModel

    /// Compact = iPhone (or iPad in narrow split-screen multitasking)
    /// Regular = iPad full-screen or landscape
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Call overlays
    @State private var callManager = CallManager.shared

    var body: some View {
        callContent
            .debugMetricsOverlay()
            // In-app incoming call sheet (CallKit handles lock-screen / background)
            #if os(iOS)
            .overlay(alignment: .bottom) {
                if case .incoming(let session) = callManager.state {
                    IncomingCallView(session: session)
                        .zIndex(100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isIncomingState)
                }
            }
            .fullScreenCover(isPresented: .constant(isActiveOrConnecting)) {
                if let session = activeCallSession {
                    InCallView(session: session, isConnecting: isConnectingState, endReason: callEndReason)
                }
            }
            #endif
    }

    @ViewBuilder
    private var callContent: some View {
        if horizontalSizeClass == .regular {
            ChatsSplitView()
                .environment(chatsViewModel)
        } else {
            @Bindable var vm = chatsViewModel
            TabView(selection: $vm.selectedTab) {
                ChatsListView()
                    .environment(chatsViewModel)
                    .tabItem {
                        Label("chats", systemImage: "message")
                    }
                    .tag(0)

                // iOS 26: TabView eagerly initialises @FetchRequest for ALL tabs during
                // layout, even unvisited ones. LazyTabContent defers mounting until
                // the tab's onAppear fires (i.e. first visit), keeping CoreData safe.
                LazyTabContent { SynapsView().environment(chatsViewModel) }
                    .tabItem {
                        Label("synaps", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    }
                    .tag(1)

                #if os(iOS)
                if CallsFeature.isEnabled {
                    LazyTabContent { CallHistoryView() }
                        .tabItem {
                            Label(NSLocalizedString("calls_tab", comment: ""), systemImage: "phone")
                        }
                        .tag(2)
                }

                LazyTabContent { SettingsView().environment(chatsViewModel) }
                    .tabItem {
                        Label("settings", systemImage: "gear")
                    }
                    .tag(CallsFeature.isEnabled ? 3 : 2)
                #endif
            }
            #if os(iOS)
            .toolbarBackground(Color.Construct.bg, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.dark, for: .tabBar)
            #endif
        }
    }

    // MARK: - Call state helpers

    private var isIncomingState: Bool {
        if case .incoming = callManager.state { return true }
        return false
    }

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
#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    
    guard context.persistentStoreCoordinator != nil else {
        fatalError("Preview Core Data context not ready")
    }
    
    let authViewModel = AuthViewModel(context: context)
    authViewModel.configureMockAuth()
    
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)

    // Create sample chats
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")
    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)
    try? context.save()

    return MainTabView()
        .environment(\.managedObjectContext, context)
        .environment(authViewModel)
        .environment(chatsViewModel)
        .environment(SecurityViewModel())
}
#endif
