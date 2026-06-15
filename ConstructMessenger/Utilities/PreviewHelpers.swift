//
//  PreviewHelpers.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 14.12.2025.
//

import Foundation
import CoreData
import SwiftUI
import os.log

/// Helper to detect if running in SwiftUI Preview mode
struct PreviewDetector {
    static var isRunningInPreview: Bool {
        // Method 1: Check environment variable (most reliable for Xcode Previews)
        let environment = ProcessInfo.processInfo.environment
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
            environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1" {
            return true
        }

        // Method 2: Xcode 17 JIT previews inject __preview.dylib without
        // always setting XCODE_RUNNING_FOR_PREVIEWS.
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("__preview.dylib") == true ||
            environment["DYLD_INSERT_LIBRARIES"]?.contains("PreviewsInjection") == true {
            return true
        }

        // Method 3: Check process name - only in simulator
        #if targetEnvironment(simulator)
        let processName = ProcessInfo.processInfo.processName
        // Check for "Previews" with capital P to avoid false positives
        if processName.contains("Previews") {
            return true
        }
        #endif

        return false
    }
}

struct PreviewHelpers {
    /// Creates an in-memory CoreData stack for SwiftUI previews
    static func createPreviewContainer() -> NSPersistentContainer {
        // Try to load model from bundle explicitly
        let container: NSPersistentContainer

        if let modelURL = Bundle.main.url(forResource: "ConstructMessenger", withExtension: "momd"),
           let managedObjectModel = NSManagedObjectModel(contentsOf: modelURL) {
            Log.info("Loading CoreData model from bundle")
            container = NSPersistentContainer(name: "ConstructMessenger", managedObjectModel: managedObjectModel)
        } else {
            Log.info("Fallback: Loading CoreData model by name")
            container = NSPersistentContainer(name: "ConstructMessenger")
        }

        // Use in-memory store for preview
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                Log.info("Preview CoreData Error: \(error), \(error.userInfo)")
                loadError = error
            } else {
                Log.info("Preview CoreData loaded successfully")
            }
            semaphore.signal()
        }

        // Wait for store to load
        _ = semaphore.wait(timeout: .now() + 5)

        if let error = loadError {
            // In-memory store failed — extremely unlikely. Return a broken container;
            // preview will show empty state rather than crashing the Xcode canvas.
            Log.info("Preview CoreData failed to load: \(error)")
        }

        return container
    }

    /// Creates sample User for preview
    static func createSampleUser(context: NSManagedObjectContext, id: String = "user1", username: String = "john_doe", displayName: String = "John Doe") -> User {
        let user = User(context: context)
        user.id = id
        user.username = username
        user.displayName = displayName
        return user
    }

    /// Creates sample Chat for preview
    static func createSampleChat(context: NSManagedObjectContext, with user: User, unread: Int16 = 0) -> Chat {
        let chat = Chat(context: context)
        chat.id = UUID().uuidString
        chat.otherUser = user
        chat.lastMessageTime = Date()
        chat.unreadCount = unread
        return chat
    }

    /// Creates sample Message for preview
    static func createSampleMessage(context: NSManagedObjectContext, chat: Chat, isSentByMe: Bool, text: String, timestamp: Date? = nil) -> Message {
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.chat = chat
        message.isSentByMe = isSentByMe
        message.timestamp = timestamp ?? Date()
        message.deliveryStatus = isSentByMe ? .delivered : .sent
        message.retryCount = 0
        message.applyStoredEncryption(plaintext: text, contactId: "preview")
        return message
    }
}
