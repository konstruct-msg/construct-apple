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

                    Text("Add Contact")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Scan a QR code or share your contact link to add verified contacts")
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
                            Text("Scan QR Code")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 32)

                    Text("Your contact link is in Account Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .navigationTitle("New Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
        // Parse URL: construct://add-contact?id=USER_ID&username=USERNAME
        guard url.hasPrefix("construct://add-contact"),
              let components = URLComponents(string: url),
              let queryItems = components.queryItems else {
            print("Invalid contact URL format")
            return
        }

        // Extract parameters
        var userId: String?
        var username: String?

        for item in queryItems {
            if item.name == "id" {
                userId = item.value
            } else if item.name == "username" {
                username = item.value
            }
        }

        guard let userId = userId, let username = username else {
            print("Missing required parameters in contact URL")
            return
        }

        // Create or fetch user
        addContact(userId: userId, username: username)

        showingQRScanner = false
        dismiss()
    }

    private func addContact(userId: String, username: String) {
        // Check if user already exists
        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)

        let user: User
        if let existingUser = try? viewContext.fetch(fetchRequest).first {
            user = existingUser
            print("User already exists: @\(username)")
        } else {
            // Create new user
            user = User(context: viewContext)
            user.id = userId
            user.username = username
            user.displayName = username

            try? viewContext.save()
            print("Added new contact: @\(username)")
        }

        // Start chat with user
        let publicUserInfo = PublicUserInfo(
            id: user.id,
            username: user.username,
            avatarUrl: nil,
            bio: nil
        )
        if let chat = chatsViewModel.startChat(with: publicUserInfo) {
            print("Chat created with @\(username)")
        }
    }
}
