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

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)

                    Text("add_contact")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("scan_qr_code_or_share_link")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 16) {
                    Button {
                        showingQRScanner = true
                    } label: {
                        HStack {
                            Image(systemName: "qrcode.viewfinder")
                            Text("scan_qr_code")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 32)

                    Text("your_contact_link_is_in_account_settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
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
        }
    }

    private func handleScannedContact(_ url: String) {
        print("🔍 NewChatView: Handling scanned URL: \(url)")

        // Parse URL: construct://add-contact?id=USER_ID&username=USERNAME
        guard url.hasPrefix("construct://add-contact") else {
            print("❌ Invalid URL prefix: \(url)")
            return
        }

        guard let components = URLComponents(string: url) else {
            print("❌ Failed to parse URL components from: \(url)")
            return
        }

        guard let queryItems = components.queryItems else {
            print("❌ No query items in URL: \(url)")
            return
        }

        print("📋 Query items: \(queryItems)")

        // Extract parameters
        var userId: String?
        var username: String?

        for item in queryItems {
            print("  - \(item.name) = \(item.value ?? "nil")")
            if item.name == "id" {
                userId = item.value
            } else if item.name == "username" {
                username = item.value
            }
        }

        guard let userId = userId, !userId.isEmpty,
              let username = username, !username.isEmpty else {
            print("❌ Missing or empty required parameters - userId: \(userId ?? "nil"), username: \(username ?? "nil")")
            return
        }

        print("✅ Parsed contact: userId=\(userId), username=\(username)")

        // Create or fetch user
        addContact(userId: userId, username: username)

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
            print("✅ NewChatView: Chat created with @\(username), chat.id=\(chat.id ?? "nil"), chat.otherUser?.id=\(chat.otherUser?.id ?? "nil")")
        } else {
            print("❌ NewChatView: Failed to create chat with @\(username)")
        }
    }
}
