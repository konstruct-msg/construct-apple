//
//  AuthViewModel+DeviceLink.swift
//  Construct Messenger
//
//  Part of AuthViewModel: device-link completion and the profile fetch that follows it.
//

import Foundation
import CoreData
import GRPCCore
#if canImport(UIKit)
import UIKit
#endif

extension AuthViewModel {
    /// Unified post-link bootstrap for Flow A (confirm) and Flow B (join request / approve).
    func completeDeviceLink(_ outcome: DeviceLinkOutcome) async {
        Log.info("completeDeviceLink role=\(outcome.role) deviceId=\(outcome.deviceId.prefix(8))…", category: "DeviceLink")

        currentUserId = outcome.userId
        isAuthenticated = true
        hasRegisteredDeviceKeys = true

        if outcome.role == .linkedNewDevice {
            // A device that joins an account has not seen its phrase, so it holds no address for
            // it. One left from an earlier account on this device would go into the cards.
            KeychainManager.shared.deleteOwnAccountAddress()
        }

        if outcome.role == .linkedNewDevice, !CryptoManager.shared.isInitialized {
            CryptoManager.shared.resetOrchestratorStateForDeviceLink()
            CryptoManager.shared.setLocalUserId(outcome.userId)
        }

        await refreshUserProfileFromServer(userId: outcome.userId)
        finishAuthenticatedSession(userId: outcome.userId, reason: "device_link")

        guard DeviceLinkHistorySyncPolicy.isOffered else {
            deviceLinkPhase = .idle
            Log.info("Post-link history sync disabled — continuing with account only", category: "DeviceLink")
            return
        }

        Log.info("Post-link history sync offered role=\(outcome.role)", category: "DeviceLink")
        switch outcome.role {
        case .linkedNewDevice:
            #if os(macOS)
            let pendingId = outcome.pendingDeviceId ?? outcome.deviceId
            deviceLinkPhase = .historySyncReceive(pendingDeviceId: pendingId)
            #else
            deviceLinkPhase = .historySyncReceive(pendingDeviceId: outcome.deviceId)
            #endif
        case .approvedJoinRequest:
            #if os(iOS)
            if let pendingId = outcome.pendingDeviceId {
                deviceLinkPhase = .historySyncSend(pendingDeviceId: pendingId)
            }
            #endif
        }
    }

    func clearDeviceLinkPhase() {
        deviceLinkPhase = .idle
    }

    private func refreshUserProfileFromServer(userId: String) async {
        do {
            let profile = try await UserServiceClient.shared.getUserProfile(userId: userId)
            let username = profile.username.isEmpty ? nil : profile.username
            loadUserFromCoreData(userId: userId, username: username)
        } catch {
            Log.debug("Profile fetch after device link failed (non-fatal): \(error)", category: "DeviceLink")
        }
    }
}
