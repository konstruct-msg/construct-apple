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

    @EnvironmentObject var chatsViewModel: ChatsViewModel
    @State private var showingQRScanner = false
    @State private var navigationPath = NavigationPath()

    init() {
        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Chat.lastMessageTime, ascending: false)]

        _chats = FetchRequest<Chat>(fetchRequest: fetchRequest, animation: .default)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                ForEach(chats) { chat in
                    NavigationLink(value: chat.id) {
                        ChatRowView(chat: chat)
                    }
                }
                .onDelete(perform: deleteItems)
            }
            .navigationDestination(for: String.self) { chatId in
                if let chat = chats.first(where: { $0.id == chatId }) {
                    ChatView(chat: chat, context: viewContext)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ConnectionStatusIndicator()
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingQRScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                }
            }
            .sheet(isPresented: $showingQRScanner) {
                QRScannerView { contactURL in
                    handleScannedContact(contactURL)
                }
            }
            .onAppear {
                chatsViewModel.setContext(viewContext)
            }
            .onChange(of: chatsViewModel.chatToOpen) { chatId in
                if let chatId = chatId {
                    // Clear the flag first to prevent re-triggering
                    chatsViewModel.chatToOpen = nil
                    // Give CoreData a moment to update the fetch request
                    Task { @MainActor in
                        // Small delay to ensure @FetchRequest has updated with the new chat
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        // Navigate to the chat
                        navigationPath.append(chatId)
                    }
                }
            }
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            offsets.map { chats[$0] }.forEach(chatsViewModel.deleteChat)
        }
    }

    // MARK: - QR Code Handling
    private func handleScannedContact(_ urlString: String) {
        print("🔍 ChatsListView: Handling scanned URL: \(urlString)")

        guard let url = URL(string: urlString) else {
            print("❌ Invalid URL string: \(urlString)")
            // TODO: Show alert to user
            return
        }

        do {
            let contactInfo = try LinkParser.parseContactLink(url)
            print("✅ Parsed contact: userId=\(contactInfo.userId), username=\(contactInfo.username)")
            
            addContact(userId: contactInfo.userId, username: contactInfo.username)
        } catch {
            print("❌ Failed to parse contact link: \(error.localizedDescription)")
            // TODO: Show alert to user with specific error message
        }

        // Close scanner
        showingQRScanner = false
    }

    private func addContact(userId: String, username: String) {
        print("📱 ChatsListView: Adding contact userId=\(userId), username=\(username)")

        // Start chat with user - ChatsViewModel handles User creation
        let publicUserInfo = PublicUserInfo(
            id: userId,
            username: username,
            avatarUrl: nil,
            bio: nil
        )
        if let chat = chatsViewModel.startChat(with: publicUserInfo) {
            print("✅ ChatsListView: Chat created with @\(username)")
            print("   chat.id = \(chat.id)")
            print("   chat.otherUser?.id = \(chat.otherUser?.id ?? "nil")")
            print("   chat.otherUser?.username = \(chat.otherUser?.username ?? "nil")")
            print("   chat.otherUser?.displayName = \(chat.otherUser?.displayName ?? "nil")")
        } else {
            print("❌ ChatsListView: Failed to create chat with @\(username)")
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

