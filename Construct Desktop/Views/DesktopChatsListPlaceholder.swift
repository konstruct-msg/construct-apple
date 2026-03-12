//
//  DesktopChatsListPlaceholder.swift
//  Construct Desktop
//
//  Sidebar chat list for the macOS app.
//  This is a temporary placeholder — once ChatsViewModel and the shared
//  iOS views are added to this target, replace with the real ChatsListView.
//

import SwiftUI
import CoreData

struct DesktopChatsListPlaceholder: View {
    @Binding var selectedChatID: NSManagedObjectID?

    var body: some View {
        List(selection: $selectedChatID) {
            Section {
                Label("New conversation", systemImage: "square.and.pencil")
                    .foregroundStyle(.accent)
            }
            Section("Conversations") {
                Text("No conversations yet")
                    .foregroundStyle(.tertiary)
                    .font(.subheadline)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Construct")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    // TODO: open new chat sheet
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New conversation (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
