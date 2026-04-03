//
//  MainTabView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

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
            VStack(spacing: 0) {
                tabContent(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CTTabBar(selected: $vm.selectedTab, items: tabItems)
                    .background(Color.CT.bg)
            }
            .ctBackground()
        }
    }

    /// Renders all tab views simultaneously (ZStack) so scroll/nav state is preserved.
    @ViewBuilder
    private func tabContent(vm: ChatsViewModel) -> some View {
        ZStack {
            ChatsListView()
                .environment(chatsViewModel)
                .opacity(vm.selectedTab == 0 ? 1 : 0)
                .allowsHitTesting(vm.selectedTab == 0)

            SynapsView()
                .environment(chatsViewModel)
                .opacity(vm.selectedTab == 1 ? 1 : 0)
                .allowsHitTesting(vm.selectedTab == 1)

            #if os(iOS)
            if CallsFeature.isEnabled {
                CallHistoryView()
                    .opacity(vm.selectedTab == 2 ? 1 : 0)
                    .allowsHitTesting(vm.selectedTab == 2)
            }

            SettingsView()
                .opacity(vm.selectedTab == (CallsFeature.isEnabled ? 3 : 2) ? 1 : 0)
                .allowsHitTesting(vm.selectedTab == (CallsFeature.isEnabled ? 3 : 2))
            #endif
        }
    }

    private var tabItems: [CTTabItem] {
        #if os(iOS)
        var items: [CTTabItem] = [
            CTTabItem(symbol: CTSymbol.tabChats,  label: "MSG"),
            CTTabItem(symbol: CTSymbol.tabSynaps, label: "SYN"),
        ]
        if CallsFeature.isEnabled {
            items.append(CTTabItem(symbol: CTSymbol.tabCalls, label: "TEL"))
        }
        items.append(CTTabItem(symbol: CTSymbol.tabSettings, label: "CFG"))
        return items
        #else
        return CTTabBar.defaultItems
        #endif
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
