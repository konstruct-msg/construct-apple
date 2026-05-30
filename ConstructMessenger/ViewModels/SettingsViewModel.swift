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
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
class SettingsViewModel {
    var displayName: String = ""
    var username: String = ""
    var userId: String = ""
    var profileImage: PlatformImage?
    var showResetAllSessionsConfirm = false
    var showDeleteKeysConfirm = false

    /// Best available name for display and invite embedding:
    /// prefers displayName, falls back to username, falls back to nil.
    var resolvedDisplayName: String? {
        if !displayName.isEmpty { return displayName }
        if !username.isEmpty { return username }
        return nil
    }

    // Username save state
    var isSavingUsername = false
    var usernameSaveError: String?
    var usernameSaved = false

    // Discoverable state — cached in UserDefaults, synced with server on load/toggle
    var isDiscoverable: Bool = UserDefaults.standard.bool(forKey: "is_discoverable")
    var isLoadingDiscoverable: Bool = false
    var discoverableError: String?

    private var viewContext: NSManagedObjectContext?
    private var avatarLoadAttemptUserId: String?

    /// Exposed read-only for platform-specific views (e.g. Desktop avatar removal).
    var viewContextPublic: NSManagedObjectContext? { viewContext }

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }

    /// Prevents redundant reloads on repeated onAppear while still allowing refresh
    /// when auth identity data changed or avatar wasn't loaded for this user yet.
    func needsUserInfoRefresh(from authViewModel: AuthViewModel) -> Bool {
        let latestUserId = authViewModel.currentUserId ?? AuthSessionManager.shared.currentUserId ?? ""
        if userId != latestUserId { return true }
        if username != authViewModel.currentUsername { return true }
        if displayName != authViewModel.currentDisplayName { return true }
        if !latestUserId.isEmpty && avatarLoadAttemptUserId != latestUserId { return true }
        return false
    }

    func loadUserInfo(from authViewModel: AuthViewModel) {
        guard let _ = viewContext else {
            Log.info("SettingsViewModel: viewContext is nil")
            return
        }

        userId = authViewModel.currentUserId ?? AuthSessionManager.shared.currentUserId ?? ""
        username = authViewModel.currentUsername
        displayName = authViewModel.currentDisplayName

        Log.info("SettingsViewModel: Loaded user info")
        Log.info("   userId: \(userId)")
        Log.info("   username: \(username)")
        Log.info("   displayName: \(displayName)")

        // Load avatar from Core Data
        loadAvatarFromCoreData()
    }

    /// Loads avatar from the current user's User entity in Core Data
    private func loadAvatarFromCoreData() {
        guard let context = viewContext, !userId.isEmpty else { return }
        avatarLoadAttemptUserId = userId
        
        // FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            Log.info("Core Data persistent store coordinator not ready, skipping avatar load")
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
    func saveAvatar(_ image: PlatformImage, authViewModel: AuthViewModel) {
        guard let context = viewContext, !userId.isEmpty else {
            Log.info("Cannot save avatar: context or userId missing")
            return
        }
        
        // Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            Log.info("Core Data persistent store coordinator not ready, cannot save avatar")
            return
        }

        // Optimize image using MediaOptimizer (512×512 square, JPEG 0.8)
        guard let processedData = try? MediaOptimizer.optimizeAvatar(image) else {
            Log.info("Failed to process avatar image")
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
                avatarLoadAttemptUserId = userId
                Log.info("Avatar saved successfully")

                // Re-send profile to all contacts we share with so they see the new avatar
                Task {
                    let shareVM = ProfileShareViewModel(context: context)
                    shareVM.rebroadcastProfileToSharedContacts()
                }
            } else {
                Log.info("User not found in Core Data")
            }
        } catch {
            Log.info("Failed to save avatar: \(error)")
        }
    }

    /// Saves username to the server and updates local state
    func saveUsername(_ newUsername: String, authViewModel: AuthViewModel) async {
        let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed != authViewModel.currentUsername else { return }

        guard trimmed.count >= MessageSizeLimits.minUsernameCharacters,
              trimmed.count <= MessageSizeLimits.maxUsernameCharacters else {
            usernameSaveError = "username_length_error"
            return
        }

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
                    context.saveAndLog()
                }
            }
            username = trimmed
            usernameSaved = true
        } catch {
            usernameSaveError = error.userFacingMessage
        }

        isSavingUsername = false
    }

    /// Saves display name to Core Data
    func saveDisplayName(_ name: String, authViewModel: AuthViewModel) {
        guard let context = viewContext, !userId.isEmpty else { return }
        
        // FIX: Check if persistent store coordinator is ready before accessing entities
        guard context.persistentStoreCoordinator != nil else {
            Log.info("Core Data persistent store coordinator not ready, cannot save display name")
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= MessageSizeLimits.maxDisplayNameCharacters else { return }

        let fetchRequest = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        fetchRequest.fetchLimit = 1

        do {
            if let user = try context.fetch(fetchRequest).first {
                user.displayName = trimmed
                try context.save()
                
                // Update local state
                displayName = trimmed
                // @Observable AuthViewModel tracks property access automatically
                
                Log.info("Display name saved: \(trimmed)")

                // Re-send profile to all contacts we share with so they see the updated name
                Task {
                    let shareVM = ProfileShareViewModel(context: context)
                    shareVM.rebroadcastProfileToSharedContacts()
                }
            }
        } catch {
            Log.error("Failed to save display name: \(error)")
        }
    }

    // MARK: - Discoverable

    /// Syncs the discoverable flag from local cache.
    /// The server doesn't currently expose the searchable field in GetUserProfile,
    /// so UserDefaults is the source of truth (set explicitly by the user on this device).
    func loadDiscoverableFromProfile() async {
        isDiscoverable = UserDefaults.standard.bool(forKey: "is_discoverable")
    }

    /// Sends the discoverable toggle to the server and updates local cache.
    func setDiscoverable(_ enabled: Bool) async {
        guard !enabled || !username.isEmpty else {
            discoverableError = "searchable_no_username_hint"
            return
        }
        isLoadingDiscoverable = true
        discoverableError = nil
        defer { isLoadingDiscoverable = false }

        do {
            try await UserServiceClient.shared.setDiscoverable(enabled: enabled)
            isDiscoverable = enabled
            UserDefaults.standard.set(enabled, forKey: "is_discoverable")
        } catch {
            discoverableError = error.userFacingMessage
        }
    }
}
