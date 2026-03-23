//
//  SpamHeuristics.swift
//  Construct Messenger
//
//  Rule-based spam scoring — runs entirely on-device, never sends content to server.
//

import Foundation

/// Heuristic spam scorer.  All analysis stays on device.
///
/// Score ranges:
///  - 0.0–0.29  Normal — allow, no PoW
///  - 0.30–0.59 Suspicious — soft delay
///  - 0.60–0.84 Likely spam — hard delay
///  - 0.85+     High confidence spam — warn user
struct SpamHeuristics {

    // MARK: - Sliding window for duplicate detection

    /// Ring buffer of hashes of recent outgoing messages (last N).
    private static var recentHashes: [Int] = []
    private static let windowSize = 10

    // MARK: - Public API

    /// Compute a spam score for an outgoing message.
    ///
    /// - Parameters:
    ///   - text: Plaintext body (not yet encrypted).
    ///   - urls: URLs extracted from the message.
    /// - Returns: Float in [0, 1].
    func score(text: String, urls: [URL] = []) -> Float {
        var total: Float = 0.0

        // Short text + at least one link is a classic phishing/spam pattern
        if text.count < 10 && !urls.isEmpty {
            total += 0.4
        }

        // Flood detection — same message sent 5+ times in recent window
        let h = text.hashValue
        let duplicates = SpamHeuristics.recentHashes.filter { $0 == h }.count
        if duplicates >= 5 {
            total += 0.5
        } else if duplicates >= 3 {
            total += 0.2
        }

        // Too many links in one message
        if urls.count > 3 {
            total += 0.3
        } else if urls.count == 3 {
            total += 0.1
        }

        // Phishing / known-bad domain
        if urls.contains(where: { PhishingDomainList.shared.isBlocked($0.host ?? "") }) {
            total += 0.6
        }

        return min(total, 1.0)
    }

    /// Call after a message was successfully queued for sending (updates duplicate window).
    static func recordSent(text: String) {
        recentHashes.append(text.hashValue)
        if recentHashes.count > windowSize {
            recentHashes.removeFirst()
        }
    }
}

// MARK: - PhishingDomainList

/// Lightweight phishing/scam domain blocklist (client-only, no server lookup).
/// Seeded with a curated starter list; can be extended via a bundled JSON file later.
final class PhishingDomainList {
    static let shared = PhishingDomainList()

    private var blocked: Set<String>

    private init() {
        // Starter list of commonly-abused domains from public phishing databases.
        // Extend by shipping a `phishing_domains.json` in the app bundle.
        blocked = [
            // Generic crypto/NFT scam patterns (exact low-level domains)
            "wallet-verify.com", "metamask-confirm.net", "token-claim.io",
            "airdrop-verify.com", "nft-mint-free.io", "crypto-giveaway.net",
            // Fake bank / payment spoofs
            "secure-paypal.com", "paypal-verify.net", "bank-secure-login.com",
            "appleid-verify.net", "apple-account-help.com",
            // Telegram / WhatsApp impersonation
            "telegram-prize.com", "whatsapp-verify.net",
            // Generic phish
            "free-gift-claim.com", "prize-winner-2024.com", "click-and-earn.net",
        ]

        // Load bundle override if present
        if let url = Bundle.main.url(forResource: "phishing_domains", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            blocked.formUnion(list)
        }
    }

    func isBlocked(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: .init(charactersIn: "www."))
        return blocked.contains(normalized) || blocked.contains("www.\(normalized)")
    }
}
