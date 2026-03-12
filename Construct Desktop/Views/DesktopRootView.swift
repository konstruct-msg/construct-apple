//
//  DesktopRootView.swift
//  Construct Desktop
//
//  Root NavigationSplitView for macOS.
//  Sidebar = chats list, Detail = active chat or placeholder.
//
//  Once the shared ViewModels are added to this target via Target Membership,
//  replace the placeholder columns with the real iOS views — they already
//  work on macOS since they use only SwiftUI APIs.
//

import SwiftUI
import CoreData

struct DesktopRootView: View {
    @Environment(\.managedObjectContext) private var viewContext

    /// Tracks which chat is selected in the sidebar. Will be wired to ChatsViewModel.
    @State private var selectedChatID: NSManagedObjectID?

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // MARK: - Sidebar: chats list
            DesktopChatsListPlaceholder(selectedChatID: $selectedChatID)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            // MARK: - Detail: active chat
            if selectedChatID != nil {
                Text("Chat view — coming soon")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            } else {
                DesktopEmptyDetailView()
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

// MARK: - Empty detail state

private struct DesktopEmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Select a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("or start a new one with ⌘N")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    DesktopRootView()
        .environment(\.managedObjectContext, PersistenceController(inMemory: true).container.viewContext)
}
