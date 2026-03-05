//
//  DisplayNameGenerator.swift
//  Construct Messenger
//
//  Generates human-readable anonymous names for privacy
//  Uses deterministic adjective+animal based on userId hash
//

import Foundation
import CryptoKit

/// Generates friendly, anonymous display names for users without usernames
/// Format: "Adjective Animal" (e.g., "Silent Dolphin", "Happy Fox")
struct DisplayNameGenerator {
    
    // MARK: - Word Lists
    
    private static let adjectives = [
        "Silent", "Happy", "Swift", "Brave", "Gentle", "Calm", "Bright", "Bold", "Quick", "Quiet",
        "Wise", "Noble", "Free", "Kind", "Pure", "Jolly", "Witty", "Fierce", "Proud", "Sly",
        
        "Lucky", "Cheerful", "Jovial", "Merry", "Clever", "Cunning", "Valiant", "Humble",
        "Clear", "Cool", "Warm", "Soft", "Strong", "Wild", "Misty", "Sunny", "Cloudy", "Starry",
        
        "Frosty", "Stormy", "Ember", "Blazing", "Frozen", "Mountain", "Ocean", "River", "Forest",
        "Desert", "Volcanic", "Thunder", "Solar", "Lunar", "Celestial", "Crystal", "Golden",
        
        "Silver", "Copper", "Iron", "Obsidian", "Amber", "Crimson", "Azure", "Verdant",
        "Sleek", "Sharp", "Smooth", "Tall", "Deep", "Light", "Dark", "Ancient", "Agile",
        
        "Majestic", "Elegant", "Graceful", "Giant", "Tiny", "Nimble", "Radiant", "Gleaming",
        "Shadowy", "Whispering", "Echoing", "Vivid", "Mystic", "Hidden", "Lonely", "Weathered"
    ]
    
    private static let animals = [
        "Fox", "Wolf", "Bear", "Lion", "Tiger", "Panda", "Jaguar", "Panther", "Leopard", "Cheetah",
        "Lynx", "Cougar", "Hyena", "Jackal", "Dingo", "Wolverine", "Otter", "Seal", "Orca", "Dolphin",
        "Whale", "Shark", "Ferret", "Mongoose", "Badger",
        
        "Deer", "Moose", "Elk", "Bison", "Hare", "Rabbit", "Squirrel", "Beaver", "Hedgehog",
        "Bat", "Boar", "Ox", "Ram", "Stag", "Marten", "Meerkat",
        
        "Eagle", "Hawk", "Owl", "Raven", "Falcon", "Swan", "Dove", "Crane", "Heron", "Sparrow",
        "Robin", "Finch", "Wren", "Phoenix", "Crow", "Vulture", "Albatross", "Kingfisher", "Kestrel",
        "Harrier", "Gull", "Penguin", "Peacock", "Parrot", "Hornbill", "Nightjar",
        
        "Dragon", "Griffin", "Unicorn", "Pegasus", "Basilisk", "Chimera", "Kraken", "Hydra",
        "Manticore", "Gryphon", "Yeti", "Kitsune", "Sphinx", "Serpent",
        
        "Cobra", "Viper", "Python", "Rattler", "Gecko", "Iguana", "Scorpion", "Spider",
        "Mantis", "Beetle", "Butterfly", "Moth", "Dragonfly",
        
        "Mammoth", "Saber", "Raptor", "Tricera", "Rex", "Titan", "Direwolf"
    ]
    
    // MARK: - Generation
    
    /// Generate a stable, anonymous display name from userId
    /// - Parameter userId: User's UUID (or deviceId)
    /// - Returns: Friendly name like "Silent Dolphin"
    static func generate(from userId: String) -> String {
        // Hash userId to get deterministic indices
        let hash = SHA256.hash(data: Data(userId.utf8))
        let hashBytes = Array(hash)
        
        func getIndex(from bytes: ArraySlice<UInt8>, modulo: Int) -> Int {
                    let slice = bytes.prefix(4)
                    var value: UInt32 = 0
                    for (i, byte) in slice.enumerated() {
                        value |= UInt32(byte) << (24 - (i * 8))
                    }
                    return Int(value % UInt32(modulo))
                }
                
                let adjIndex = getIndex(from: hashBytes[0...], modulo: adjectives.count)
                let animalIndex = getIndex(from: hashBytes[4...], modulo: animals.count)
                
                return "\(adjectives[adjIndex]) \(animals[animalIndex])"
    }
    
    /// Generate short ID (first 6 chars of hash) as fallback
    /// - Parameter userId: User's UUID
    /// - Returns: Short hex like "a3f8c2"
    static func generateShortId(from userId: String) -> String {
        let hash = SHA256.hash(data: Data(userId.utf8))
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hashHex.prefix(6))
    }
}

// MARK: - User Extension

extension User {
    /// Get display name for UI
    /// Priority: displayName > username > anonymous name
    var effectiveDisplayName: String {
        if !displayName.isEmpty {
            return displayName
        }
        if !username.isEmpty {
            return username
        }
        // Generate anonymous name from userId
        return DisplayNameGenerator.generate(from: id )
    }
    
    /// Get username with @ prefix (only if username exists)
    var formattedUsername: String? {
        guard !username.isEmpty else {
            return nil
        }
        return "@\(username)"
    }
    
    /// Get short display for lists (prioritizes brevity)
    var shortDisplayName: String {
        if !username.isEmpty {
            return username
        }
        if !displayName.isEmpty, displayName.count <= 20 {
            return displayName
        }
        // Anonymous name for privacy
        return DisplayNameGenerator.generate(from: id)
    }
}

// MARK: - PublicUserInfo Extension

extension PublicUserInfo {
    /// Get display name for UI
    var effectiveDisplayName: String {
        if !username.isEmpty {
            return username
        }
        // Generate anonymous name from userId
        return DisplayNameGenerator.generate(from: id)
    }
    
    /// Get username with @ prefix (only if exists)
    var formattedUsername: String? {
        guard !username.isEmpty else {
            return nil
        }
        return "@\(username)"
    }
}
