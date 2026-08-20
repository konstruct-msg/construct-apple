//
//  KeychainRead.swift
//  Construct Messenger
//
//  The result of one Keychain read, with "not there" and "could not read it" kept apart.
//
//  `Data?` cannot carry that distinction, and on 2026-08-09 it cost a user their account:
//  `errSecItemNotFound` and `errSecInteractionNotAllowed` were both `nil`, so a locked device
//  read as an unregistered one. See `DeviceKeyAvailability` for the incident.
//
//  This does not replace `load(forKey:)` — most callers genuinely only care whether they got a
//  value. It exists for the reads where being wrong is destructive.
//

import Foundation

enum KeychainRead: Equatable {
    case found(Data)
    /// `errSecItemNotFound` — the item is not in the Keychain.
    case absent
    /// Any other status: locked device, protected-data unavailable, corruption. The item may
    /// well exist. `status` goes in the log so the next incident starts with a number instead
    /// of a hypothesis.
    case unreadable(OSStatus)

    var isFound: Bool { if case .found = self { return true }; return false }
    var isAbsent: Bool { self == .absent }
    var isUnreadable: Bool { if case .unreadable = self { return true }; return false }

    var data: Data? { if case .found(let data) = self { return data }; return nil }

    /// For logs: `found(32B)` / `absent` / `unreadable(-25308)`.
    var description: String {
        switch self {
        case .found(let data): return "found(\(data.count)B)"
        case .absent: return "absent"
        case .unreadable(let status): return "unreadable(\(status))"
        }
    }

    /// Classify a raw `SecItemCopyMatching` outcome.
    ///
    /// An empty payload is treated as `unreadable`, not `found`: a zero-byte signing key is not
    /// a usable identity, and it is not evidence that the user never registered either.
    static func classify(status: OSStatus, data: Data?) -> KeychainRead {
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else { return .unreadable(status) }
        guard let data, !data.isEmpty else { return .unreadable(status) }
        return .found(data)
    }
}
