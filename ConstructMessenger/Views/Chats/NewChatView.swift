//
//  NewChatView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import CoreData

// ✅ Privacy-focused contact addition
// Global user search was removed for security reasons:
// - Prevents enumeration attacks
// - No metadata leakage about who searches for whom
// - Users control who can add them (QR-code/link sharing only)

struct NewChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject var chatsViewModel: ChatsViewModel

    @State private var showingQRScanner = false
    @State private var initialContactInfo: ContactInfo?

    init(chatsViewModel: ChatsViewModel, initialContactInfo: ContactInfo? = nil) {
        self.chatsViewModel = chatsViewModel
        _initialContactInfo = State(initialValue: initialContactInfo)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                
            }
            .navigationTitle("new_contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingQRScanner) {
                QRScannerView { contactURL in
                    handleScannedContact(contactURL)
                }
            }
            .onAppear {
                if let contactInfo = initialContactInfo {
                    addContact(userId: contactInfo.userId, username: contactInfo.username)
                    initialContactInfo = nil // Consume the deep link
                }
            }
        }
    }

    private func handleScannedContact(_ urlString: String) {
        print("🔍 NewChatView: Handling scanned URL: \(urlString)")

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

        showingQRScanner = false
        dismiss()
    }

    private func addContact(userId: String, username: String) {
        print("📱 NewChatView: Adding contact userId=\(userId), username=\(username)")

        // Start chat with user - let ChatsViewModel handle User creation
        let publicUserInfo = PublicUserInfo(
            id: userId,
            username: username,
            avatarUrl: nil,
            bio: nil
        )
        if let chat = chatsViewModel.startChat(with: publicUserInfo) {
            print("✅ NewChatView: Chat created with @\(username), chat.id=\(chat.id), chat.otherUser?.id=\(chat.otherUser?.id ?? "nil")")
        } else {
            print("❌ NewChatView: Failed to create chat with @\(username)")
        }
    }
}
