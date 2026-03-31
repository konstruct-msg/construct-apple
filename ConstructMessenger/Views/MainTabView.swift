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
                    InCallView(session: session, isConnecting: isConnectingState)
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

                SynapsView()
                    .environment(chatsViewModel)
                    .tabItem {
                        Label("synaps", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    }
                    .tag(1)

                #if os(iOS)
                if CallsFeature.isEnabled {
                    CallHistoryView()
                        .tabItem {
                            Label(NSLocalizedString("calls_tab", comment: ""), systemImage: "phone")
                        }
                        .tag(2)
                }

                SettingsView()
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
        case .active, .connecting, .ringing: return true
        default: return false
        }
    }

    private var isConnectingState: Bool {
        switch callManager.state {
        case .connecting, .ringing: return true
        default: return false
        }
    }

    private var activeCallSession: CallManager.CallSession? {
        switch callManager.state {
        case .active(let s), .connecting(let s), .ringing(let s): return s
        default: return nil
        }
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
