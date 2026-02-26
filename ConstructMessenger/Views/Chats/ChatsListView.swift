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
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingDrafts = false

    init() {
        // ✅ FIX: Create fetch request safely - fetchRequest() just creates the request object
        // It doesn't access the coordinator until the fetch is actually executed
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
            .sheet(isPresented: $showingDrafts) {
                DraftsView()
            }
            .alert("error", isPresented: $showingError) {
                Button("ok") {}
            } message: {
                Text(errorMessage)
            }
            .onAppear {
                chatsViewModel.setContext(viewContext)
                // ✅ Clear badge when user opens chats list
                LocalNotificationManager.shared.clearBadge()
            }
            .onChange(of: chatsViewModel.chatToOpen) { _, chatId in
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
        Log.info("🔍 ChatsListView: Handling scanned URL: \(urlString)", category: "ChatsListView")

        guard let url = URL(string: urlString) else {
            Log.error("❌ Invalid URL string: \(urlString)", category: "ChatsListView")
            showErrorAfterDismiss(NSLocalizedString("invalid_qr_code_construct", comment: "Error message for invalid QR code"))
            return
        }

        Task {
            do {
                let contactInfo = try await LinkParser.parseContactLink(url)
                Log.info("✅ Parsed contact: userId=\(contactInfo.userId), username=\(contactInfo.username)", category: "ChatsListView")
                
                await MainActor.run {
                    addContact(userId: contactInfo.userId, username: contactInfo.username)
                    showingQRScanner = false
                }
            } catch {
                Log.error("❌ Failed to parse contact link: \(error.localizedDescription)", category: "ChatsListView")
                await MainActor.run {
                    showErrorAfterDismiss(error.localizedDescription)
                    showingQRScanner = false
                }
            }
        }
    }

    private func addContact(userId: String, username: String) {
        Log.info("📱 ChatsListView: Adding contact userId=\(userId), username=\(username)", category: "ChatsListView")

        if userId == SessionManager.shared.currentUserId {
            Log.info("📝 Self-chat detected — opening Drafts", category: "ChatsListView")
            showingDrafts = true
            return
        }

        // Start chat with user - ChatsViewModel handles User creation
        let publicUserInfo = PublicUserInfo(
            id: userId,
            username: username,
            avatarUrl: nil,
            bio: nil
        )
        if let chat = chatsViewModel.startChat(with: publicUserInfo) {
            Log.info("✅ ChatsListView: Chat created with @\(username), chat.id=\(chat.id)", category: "ChatsListView")
        } else {
            Log.error("❌ ChatsListView: Failed to create chat with @\(username)", category: "ChatsListView")
        }
    }

    private func showErrorAfterDismiss(_ message: String) {
        errorMessage = message
        showingQRScanner = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showingError = true
        }
    }
}

#Preview {
    let container = PreviewHelpers.createPreviewContainer()
    let context = container.viewContext
    
    // ✅ Ensure context is ready before using it
    guard context.persistentStoreCoordinator != nil else {
        fatalError("Preview Core Data context not ready")
    }

    // Create sample data
    let user1 = PreviewHelpers.createSampleUser(context: context, id: "user1", username: "alice", displayName: "Alice")
    let user2 = PreviewHelpers.createSampleUser(context: context, id: "user2", username: "bob", displayName: "Bob")

    _ = PreviewHelpers.createSampleChat(context: context, with: user1)
    _ = PreviewHelpers.createSampleChat(context: context, with: user2)

    try? context.save()
    
    let chatsViewModel = ChatsViewModel()
    chatsViewModel.setContext(context)

    return ChatsListView()
        .environment(\.managedObjectContext, context)
        .environmentObject(chatsViewModel)
}
