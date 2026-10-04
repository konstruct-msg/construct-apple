//
//  RecoveryBackupState.swift
//  Construct Messenger
//
//  Where the copy of a silently made recovery key stands, and when to ask for it.
//  `decisions/recovery-key-backup-is-deferred-not-skipped.md` §3, slice S2.
//
//  Two local facts make the answer, both per account and never sent anywhere:
//  - when the key was made silently (`RecoveryKeyProvisioner`) — a key set up through the visible
//    flow was copied by construction and leaves no mark;
//  - whether the copy was confirmed.
//
//  With those, "the phrase is not in the vault" splits into its two causes. Copied: as it should
//  be. Not copied: it is gone — the passcode was removed, and the system deleted the item that
//  depended on it. The key on the server cannot change, so the honest answer is to say so.
//

import Foundation

enum RecoveryReminder: Equatable {
    case none
    /// The copy is owed and the first days have passed.
    case backupDue
    /// The phrase left the device before it was copied.
    case phraseLost

    /// Days after the silent key before the chat list asks for the copy, and again after the
    /// person closes the reminder (owner's decision, 2026-10-04).
    static let delay: TimeInterval = 3 * 24 * 60 * 60

    /// The whole rule. `phrase` is what the vault says about the phrase being on the device.
    static func decide(
        now: Date,
        silentAt: Date?,
        copied: Bool,
        phrase: RecoveryPhrasePresence,
        snoozedUntil: Date?
    ) -> RecoveryReminder {
        guard let silentAt, !copied else { return .none }
        if let snoozedUntil, now < snoozedUntil { return .none }
        switch phrase {
        case .absent:
            return .phraseLost
        case .present, .unknown:
            return now.timeIntervalSince(silentAt) >= delay ? .backupDue : .none
        }
    }
}

/// What the vault can say about the phrase without asking the person to authenticate.
enum RecoveryPhrasePresence: Equatable {
    case present
    /// The system says there is no such item. Only this may ever read as "lost".
    case absent
    /// Anything else the Keychain answers — locked, busy, an error. Never read as lost: telling
    /// someone their key is gone when it is not is the one mistake this screen must not make.
    case unknown
}

/// The two facts, in `UserDefaults`. Wiped with the account (`AccountWipeKeys`).
struct RecoveryBackupMarks {
    static let silentAtKey = "construct.recovery.silentAt"
    static let silentAccountKey = "construct.recovery.silentAccount"
    static let copiedKey = "construct.recovery.copied"
    static let snoozedUntilKey = "construct.recovery.reminderSnoozedUntil"

    var defaults: UserDefaults = .standard

    func markSilent(account: String, at date: Date = Date()) {
        defaults.set(account, forKey: Self.silentAccountKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.silentAtKey)
        defaults.set(false, forKey: Self.copiedKey)
    }

    func silentAt(account: String) -> Date? {
        guard defaults.string(forKey: Self.silentAccountKey) == account,
              let seconds = defaults.object(forKey: Self.silentAtKey) as? Double
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func markCopied() {
        defaults.set(true, forKey: Self.copiedKey)
    }

    var copied: Bool { defaults.bool(forKey: Self.copiedKey) }

    func snooze(from now: Date = Date()) {
        defaults.set(now.addingTimeInterval(RecoveryReminder.delay).timeIntervalSince1970,
                     forKey: Self.snoozedUntilKey)
    }

    var snoozedUntil: Date? {
        (defaults.object(forKey: Self.snoozedUntilKey) as? Double).map(Date.init(timeIntervalSince1970:))
    }
}
