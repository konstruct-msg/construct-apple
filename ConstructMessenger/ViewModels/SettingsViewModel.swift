//
//  SettingsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import Foundation
import Combine
import SwiftUI
import CoreData

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var displayName: String = ""
    @Published var username: String = ""
    @Published var userId: String = ""
    @Published var profileImage: UIImage?

    private var viewContext: NSManagedObjectContext?

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }

    func loadUserInfo(from authViewModel: AuthViewModel) {
        guard let context = viewContext else { return }

        userId = authViewModel.currentUserId ?? SessionManager.shared.currentUserId ?? ""
        username = authViewModel.currentUsername ?? ""
        displayName = authViewModel.currentDisplayName ?? ""

        // Load avatar from Core Data
        loadAvatarFromCoreData()
    }

    /// Loads avatar from the current user's User entity in Core Data
    private func loadAvatarFromCoreData() {
        guard let context = viewContext, !userId.isEmpty else { return }

        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        if let user = try? context.fetch(fetchRequest).first,
           let avatarData = user.avatarData {
            profileImage = ImageHelper.imageFromData(avatarData)
        }
    }

    /// Saves avatar to Core Data using ImageHelper for processing
    func saveAvatar(_ image: UIImage) {
        guard let context = viewContext, !userId.isEmpty else {
            print("⚠️ Cannot save avatar: context or userId missing")
            return
        }

        // Process image using ImageHelper (resize, compress, etc.)
        guard let processedData = ImageHelper.prepareAvatarImage(image) else {
            print("⚠️ Failed to process avatar image")
            return
        }

        // Find current user in Core Data
        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        do {
            if let user = try context.fetch(fetchRequest).first {
                user.avatarData = processedData
                try context.save()

                // Update UI
                profileImage = ImageHelper.imageFromData(processedData)
                print("✅ Avatar saved successfully")
            } else {
                print("⚠️ User not found in Core Data")
            }
        } catch {
            print("⚠️ Failed to save avatar: \(error)")
        }
    }

    /// Saves display name to Core Data
    func saveDisplayName(_ name: String) {
        guard let context = viewContext, !userId.isEmpty else { return }

        let trimmed = name.trimmingCharacters(in: .whitespaces)

        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        do {
            if let user = try context.fetch(fetchRequest).first {
                user.displayName = trimmed
                try context.save()
                displayName = trimmed
                print("✅ Display name saved: \(trimmed)")
            }
        } catch {
            print("⚠️ Failed to save display name: \(error)")
        }
    }
}

