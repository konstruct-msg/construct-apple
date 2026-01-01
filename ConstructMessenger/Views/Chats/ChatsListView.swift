//
//  ChatsListView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

struct ChatsListView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest
    private var chats: FetchedResults<Chat>

    @StateObject private var chatsViewModel = ChatsViewModel()
    @State private var showingNewChat = false

    init() {
        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Chat.lastMessageTime, ascending: false)]

        _chats = FetchRequest<Chat>(fetchRequest: fetchRequest, animation: .default)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(chats) { chat in
                    NavigationLink {
                        ChatView(chat: chat, context: viewContext)
                    } label: {
                        ChatRowView(chat: chat)
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionStatusIndicator()
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingNewChat = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
            }
            .sheet(isPresented: $showingNewChat) {
                NewChatView(chatsViewModel: chatsViewModel)
            }
            .onAppear {
                chatsViewModel.setContext(viewContext)
            }
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { chats[$0] }.forEach(chatsViewModel.deleteChat)
        }
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext

    // Create sample data
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")

    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)

    try? context.save()

    return ChatsListView()
        .environment(\.managedObjectContext, context)
}

