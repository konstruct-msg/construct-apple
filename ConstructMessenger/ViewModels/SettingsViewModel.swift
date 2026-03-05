//
//  SettingsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import Foundation
import SwiftUI
import CoreData
import Observation

@MainActor
@Observable
class SettingsViewModel {
    var displayName: String = ""
    var username: String = ""
    var userId: String = ""
    var profileImage: UIImage?
    var showResetAllSessionsConfirm = false
    var showDeleteKeysConfirm = false

    // Username save state
    var isSavingUsername = false
    var usernameSaveError: String?
    var usernameSaved = false

    private var viewContext: NSManagedObjectContext?

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }

    func loadUserInfo(from authViewModel: AuthViewModel) {
        guard let _ = viewContext else {
            print("⚠️ SettingsViewModel: viewContext is nil")
            return
        }

        userId = authViewModel.currentUserId ?? SessionManager.shared.currentUserId ?? ""
        username = authViewModel.currentUsername
        displayName = authViewModel.currentDisplayName

        print("📋 SettingsViewModel: Loaded user info")
        print("   userId: \(userId)")
        print("   username: \(username)")
        print("   displayName: \(displayName)")

        // Load avatar from Core Data
        loadAvatarFromCoreData()
    }

    /// Loads avatar from the current user's User entity in Core Data
    private func loadAvatarFromCoreData() {
        guard let context = viewContext, !userId.isEmpty else { return }
        
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            print("⚠️ Core Data persistent store coordinator not ready, skipping avatar load")
            return
        }

        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        if let user = try? context.fetch(fetchRequest).first,
           let avatarData = user.avatarData {
            profileImage = ImageHelper.imageFromData(avatarData)
        }
    }

    /// Saves avatar to Core Data using ImageHelper for processing
    func saveAvatar(_ image: UIImage, authViewModel: AuthViewModel) {
        guard let context = viewContext, !userId.isEmpty else {
            print("⚠️ Cannot save avatar: context or userId missing")
            return
        }
        
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            print("⚠️ Core Data persistent store coordinator not ready, cannot save avatar")
            return
        }

        // Optimize image using MediaOptimizer (512×512 square, JPEG 0.8)
        guard let processedData = try? MediaOptimizer.optimizeAvatar(image) else {
            print("⚠️ Failed to process avatar image")
            return
        }

        // Find current user in Core Data
        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        do {
            if let user = try context.fetch(fetchRequest).first {
                user.avatarData = processedData
                try context.save()

                // Update UI
                profileImage = ImageHelper.imageFromData(processedData)
                print("✅ Avatar saved successfully")
                
                // Force UI refresh by posting notification
                NotificationCenter.default.post(name: .NSManagedObjectContextDidSave, object: context)
            } else {
                print("⚠️ User not found in Core Data")
            }
        } catch {
            print("⚠️ Failed to save avatar: \(error)")
        }
    }

    /// Saves username to the server and updates local state
    func saveUsername(_ newUsername: String, authViewModel: AuthViewModel) async {
        let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != authViewModel.currentUsername else { return }

        isSavingUsername = true
        usernameSaveError = nil
        usernameSaved = false

        do {
            // Check availability first
            let availability = try await UserServiceClient.shared.checkUsernameAvailability(username: trimmed)
            guard availability.available else {
                usernameSaveError = availability.reason ?? "username_already_taken"
                isSavingUsername = false
                return
            }

            // Update on server
            try await UserServiceClient.shared.updateUsername(userId: userId, username: trimmed)

            // Persist locally
            if let context = viewContext {
                let fetchRequest = User.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
                fetchRequest.fetchLimit = 1
                if let user = try? context.fetch(fetchRequest).first {
                    user.username = trimmed
                    try? context.save()
                }
            }
            username = trimmed
            usernameSaved = true
        } catch {
            usernameSaveError = error.localizedDescription
        }

        isSavingUsername = false
    }

    /// Saves display name to Core Data
    func saveDisplayName(_ name: String, authViewModel: AuthViewModel) {
        guard let context = viewContext, !userId.isEmpty else { return }
        
        // ✅ FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            print("⚠️ Core Data persistent store coordinator not ready, cannot save display name")
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespaces)

        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        do {
            if let user = try context.fetch(fetchRequest).first {
                user.displayName = trimmed
                try context.save()
                
                // ✅ REFACTOR Phase 1.2: Update local state
                displayName = trimmed
                // @Observable AuthViewModel tracks property access automatically
                
                print("✅ Display name saved: \(trimmed)")
            }
        } catch {
            print("⚠️ Failed to save display name: \(error)")
        }
    }
}

