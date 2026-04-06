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
/// ~20% chance: IT/office noun instead of animal (e.g., "Brave Printer", "Sad Protocol")
struct DisplayNameGenerator {
    
    // MARK: - Word Lists
    
    private static let adjectives = [
        "silent", "happy", "swift", "brave", "gentle", "calm", "bright", "bold", "quick", "quiet",
        "wise", "noble", "free", "kind", "pure", "jolly", "witty", "fierce", "proud", "sly",
        
        "lucky", "cheerful", "jovial", "merry", "clever", "cunning", "valiant", "humble",
        "clear", "cool", "warm", "soft", "strong", "wild", "misty", "sunny", "cloudy", "starry",
        
        "frosty", "stormy", "ember", "blazing", "frozen", "mountain", "ocean", "river", "forest",
        "desert", "volcanic", "thunder", "solar", "lunar", "celestial", "crystal", "golden",
        
        "silver", "copper", "obsidian", "amber", "crimson", "azure", "verdant",
        "sleek", "sharp", "smooth", "tall", "deep", "light", "dark", "ancient", "agile",
        
        "majestic", "elegant", "graceful", "giant", "tiny", "nimble", "radiant", "gleaming",
        "shadowy", "whispering", "echoing", "vivid", "mystic", "hidden", "lonely", "weathered",

        // bonus: for IT nouns these read even better
        "deprecated", "recursive", "async", "frozen", "nested", "compiled", "broken",
        "pending", "idle", "verbose", "headless", "orphaned", "forked", "stale", "cursed"
    ]
    
    private static let animals = [
        "fox", "wolf", "bear", "lion", "tiger", "panda", "jaguar", "panther", "leopard", "cheetah",
        "lynx", "cougar", "hyena", "jackal", "dingo", "wolverine", "otter", "seal", "orca", "dolphin",
        "whale", "shark", "ferret", "mongoose", "badger",
        
        "deer", "moose", "elk", "bison", "hare", "rabbit", "squirrel", "beaver", "hedgehog",
        "bat", "boar", "ox", "ram", "stag", "marten", "meerkat",
        
        "eagle", "hawk", "owl", "raven", "falcon", "swan", "dove", "crane", "heron", "sparrow",
        "robin", "finch", "wren", "phoenix", "crow", "vulture", "albatross", "kingfisher", "kestrel",
        "harrier", "gull", "penguin", "peacock", "parrot", "hornbill", "nightjar",
        
        "dragon", "griffin", "unicorn", "pegasus", "basilisk", "chimera", "kraken", "hydra",
        "manticore", "gryphon", "yeti", "kitsune", "sphinx", "serpent",
        
        "cobra", "viper", "python", "rattler", "gecko", "iguana", "scorpion", "spider",
        "mantis", "beetle", "butterfly", "moth", "dragonfly",
        
        "mammoth", "saber", "raptor", "tricera", "rex", "titan", "direwolf"
    ]

    /// IT / office nouns — used ~20% of the time for absurdist humour
    private static let itNouns = [
        // hardware
        "printer", "keyboard", "monitor", "server", "router", "modem", "firewall",
        "switch", "hub", "rack", "cable", "dongle", "cursor", "terminal",
        // software / concepts
        "daemon", "kernel", "process", "thread", "socket", "buffer", "pointer",
        "callback", "semaphore", "mutex", "cron", "webhook", "pipeline", "protocol",
        "endpoint", "payload", "namespace", "instance", "container", "cluster",
        "registry", "proxy", "gateway", "runtime", "compiler", "debugger",
        // office
        "spreadsheet", "invoice", "deadline", "standup", "backlog", "ticket",
        "milestone", "stakeholder", "deployment", "outage", "rollback", "hotfix",
        "sprint", "retro", "roadmap", "handover", "escalation", "pivot",
    ]
    
    // MARK: - Generation
    
    /// Generate a stable, anonymous display name from userId.
    /// Returns "Adjective Animal" ~80% of the time,
    /// or "Adjective ItNoun" ~20% of the time.
    static func generate(from userId: String) -> String {
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

        let adjIndex  = getIndex(from: hashBytes[0...], modulo: adjectives.count)
        let nounByte  = Int(hashBytes[8])   // 3rd independent byte — decides noun category
        let useITNoun = nounByte % 5 == 0   // ~20% probability

        let noun: String
        if useITNoun {
            let nounIndex = getIndex(from: hashBytes[4...], modulo: itNouns.count)
            noun = itNouns[nounIndex]
        } else {
            let animalIndex = getIndex(from: hashBytes[4...], modulo: animals.count)
            noun = animals[animalIndex]
        }

        return "\(adjectives[adjIndex]) \(noun)"
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
