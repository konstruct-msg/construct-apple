//
//  AvatarRetryService.swift
//  Construct Messenger
//
//  Retries avatar downloads a contact's profile named and that have not arrived.
//
//  A profile names its avatar in the media store; the download can fail (offline, the VEIL
//  startup window). Since model 14 the reference is kept on the contact (`pendingAvatarRef`) until
//  it arrives, the store says it is gone, or it is older than the store keeps anything — and this
//  asks again on every successful stream connect.
//
//  Until 2026-10-02 this searched saved messages for a JSON profile to re-read the reference from.
//  Profiles had been binary and unsaved for months, so it never found one: nothing was retried.
//

import Foundation

final class AvatarRetryService {
    static let shared = AvatarRetryService()
    private init() {}

    private var isRetrying = false

    /// Call after every successful stream (re)connect.
    func retryPendingAvatarsIfNeeded() {
        guard !isRetrying else { return }
        Task { await retryAll() }
    }

    private func retryAll() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }

        let pending = ((try? LocalRepositories.contacts.contactsWithPendingAvatar()) ?? []).map(\.id)
        guard !pending.isEmpty else { return }
        Log.info("AvatarRetry: \(pending.count) avatar(s) pending", category: "AvatarRetry")
        for contactId in pending {
            await ProfileSharingManager.fetchPendingAvatar(of: contactId)
        }
    }
}
