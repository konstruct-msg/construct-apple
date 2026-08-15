//
//  AccessibilityIdentifiers.swift
//  Construct Messenger
//
//  Stable identifiers for the screens the two-simulator E2E stand drives
//  (`scripts/two_sims.sh`). The consumer lives outside this repo — a UI-automation
//  agent reading the accessibility tree — so these strings are a wire contract, not
//  decoration: renaming one silently breaks a scenario that still compiles.
//
//  Identifiers are NOT localized and never user-visible. That is what makes them the
//  right channel for machine-readable state (see `Chat.messageStatus`): the delivery
//  status of a message can be asserted without inventing a user-facing string for it.
//
//  Scope is deliberately the happy path only — onboarding, pairing, the chat list and
//  send/receive. Everything else is left bare rather than pre-emptively tagged; an
//  identifier nothing drives is a string to keep in sync for free.
//

import Foundation

enum A11y {

    // MARK: - Onboarding

    enum Onboarding {
        static let username         = "onboarding.username"
        static let createIdentity   = "onboarding.createIdentity"
        static let existingIdentity = "onboarding.existingIdentity"
    }

    enum Registration {
        /// Present for every pre-complete step — the stand waits on it disappearing.
        static let preparing = "registration.preparing"
        static let complete  = "registration.complete"
        static let error     = "registration.error"
        static let `continue` = "registration.continue"
        static let retry     = "registration.retry"
        static let cancel    = "registration.cancel"
    }

    // MARK: - Shell

    enum Tab {
        static let chats    = "tab.chats"
        static let synaps   = "tab.synaps"
        static let calls    = "tab.calls"
        static let settings = "tab.settings"
    }

    // MARK: - Chats list

    enum Chats {
        static let list           = "chats.list"
        static let search         = "chats.search"
        static let scanQR         = "chats.scanQR"
        static let empty          = "chats.empty"
        static let emptyScanQR    = "chats.empty.scanQR"
        static let emptyShowQR    = "chats.empty.showQR"
        static let emptyOpenSynaps = "chats.empty.openSynaps"

        /// Keyed by conversation id so a scenario can open a specific peer rather
        /// than "the first row", which reorders on every incoming message.
        static func row(_ chatId: String) -> String { "chats.row.\(chatId)" }
    }

    // MARK: - Conversation

    enum Chat {
        static let messageList = "chat.messageList"
        static let input       = "chat.input"
        static let send        = "chat.send"
        static let voice       = "chat.voice"
        static let back        = "chat.back"
        static let title       = "chat.title"

        static func message(_ messageId: String) -> String { "chat.message.\(messageId)" }

        /// The delivery status is encoded *in the identifier* rather than exposed as a
        /// label: the icons carry no text, and the two-sim stand needs to assert
        /// "delivered" — the one status that proves the peer's receipt came back.
        static func messageStatus(_ messageId: String, _ status: DeliveryStatus) -> String {
            "chat.message.\(messageId).status.\(status.a11yToken)"
        }
    }

    // MARK: - Pairing

    enum ContactQR {
        static let code       = "contactQR.code"
        static let regenerate = "contactQR.regenerate"
        /// The camera-free pairing path: the simulator has no camera, so the QR is
        /// undrivable, but this button puts the same invite on the pasteboard — which
        /// `simctl pbpaste` can read and `simctl openurl` can hand to the other sim.
        /// It moved out of Settings into this sheet on 2026-08-15; `scripts/two_sims.sh`
        /// documents the extra tap.
        static let copyLink   = "contactQR.copyLink"
    }

    enum Settings {
        /// Opens `ContactQRCodeView` — the single invite surface (QR + copy link).
        static let invite = "settings.invite"
    }

    enum Account {
        static let fingerprint = "account.fingerprint"
    }

    /// Invites this device issued and has not yet let expire.
    enum IssuedInvites {
        static let row   = "settings.issuedInvites"
        static let empty = "issuedInvites.empty"
        /// Addressed by the act's own id, not by position: the list re-sorts as acts
        /// expire out of it, so an index would name a different row minute to minute.
        static func act(_ id: UUID) -> String { "issuedInvites.act.\(id.uuidString)" }
    }
}

extension DeliveryStatus {
    /// Stable spelling for identifiers. Deliberately not `displayName` — that one is
    /// prose ("Sent to server") and free to change with the copy.
    var a11yToken: String {
        switch self {
        case .sending:   return "sending"
        case .sent:      return "sent"
        case .delivered: return "delivered"
        case .queued:    return "queued"
        case .failed:    return "failed"
        }
    }

    /// Spoken by VoiceOver, and the reason the status appears in the accessibility tree
    /// at all — an unlabeled `Image` is dropped from it, taking the identifier with it.
    var a11yLabel: String {
        switch self {
        case .sending:   return NSLocalizedString("msg_status_sending", comment: "")
        case .sent:      return NSLocalizedString("msg_status_sent", comment: "")
        case .delivered: return NSLocalizedString("msg_status_delivered", comment: "")
        case .queued:    return NSLocalizedString("msg_status_queued", comment: "")
        case .failed:    return NSLocalizedString("msg_status_failed", comment: "")
        }
    }
}
