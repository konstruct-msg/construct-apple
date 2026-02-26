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
    @Published var showResetAllSessionsConfirm = false
    @Published var showDeleteKeysConfirm = false  // ← NEW for developer mode

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
                
                // ✅ REFACTOR Phase 1.2: Update local state and trigger AuthViewModel update
                displayName = trimmed
                // currentUser is @Published, so updating Core Data User will auto-notify
                // AuthViewModel.currentUser is the same object, computed properties will return new value
                authViewModel.objectWillChange.send()  // Force UI refresh
                
                print("✅ Display name saved: \(trimmed)")
            }
        } catch {
            print("⚠️ Failed to save display name: \(error)")
        }
    }
}

