//
//  NewChatView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI
import Combine
import CoreData

// ✅ Privacy-focused contact addition
// Global user search was removed for security reasons:
// - Prevents enumeration attacks
// - No metadata leakage about who searches for whom
// - Users control who can add them (QR-code/link sharing only)

struct NewChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    var chatsViewModel: ChatsViewModel

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
            #if os(iOS)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #endif
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
                    addContact(contactInfo: contactInfo)
                    initialContactInfo = nil // Consume the deep link
                }
            }
        }
    }

    private func handleScannedContact(_ urlString: String) {
        Log.info("NewChatView: Handling scanned URL: \(urlString)", category: "NewChatView")

        guard let url = URL(string: urlString) else {
            Log.error("Invalid URL string: \(urlString)", category: "NewChatView")
            showErrorAfterDismiss(NSLocalizedString("invalid_qr_code_construct", comment: "Error message for invalid QR code"))
            return
        }

        Task {
            do {
                let contactInfo = try await LinkParser.parseContactLink(url)
                Log.info("Parsed contact: userId=\(contactInfo.userId), username=\(contactInfo.username), isDynamic=\(contactInfo.isDynamic)", category: "NewChatView")
                
                await MainActor.run {
                    addContact(contactInfo: contactInfo)
                    showingQRScanner = false
                    dismiss()
                }
            } catch {
                Log.error("Failed to parse contact link: \(error.localizedDescription)", category: "NewChatView")
                await MainActor.run {
                    showErrorAfterDismiss(error.localizedDescription)
                    showingQRScanner = false
                }
            }
        }
    }

    private func addContact(contactInfo: ContactInfo) {
        let userId = contactInfo.userId
        let username = contactInfo.username
        Log.info("NewChatView: Adding contact userId=\(userId), username=\(username)", category: "NewChatView")

        let publicUserInfo = PublicUserInfo(
            id: userId,
            username: username,
            avatarUrl: nil,
            bio: nil,
            deviceId: contactInfo.deviceId
        )
        if let chat = chatsViewModel.startChat(with: publicUserInfo) {
            Log.info("NewChatView: Chat created with @\(username), chat.id=\(chat.id)", category: "NewChatView")
        } else {
            Log.error("NewChatView: Failed to create chat with @\(username)", category: "NewChatView")
        }
    }

    private func showErrorAfterDismiss(_ message: String) {
        showingQRScanner = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            ErrorRouter.shared.report(.unknown(message))
        }
    }
}
