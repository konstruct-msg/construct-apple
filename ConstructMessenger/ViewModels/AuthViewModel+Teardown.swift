//
//  AuthViewModel+Teardown.swift
//  Construct Messenger
//
//  Part of AuthViewModel: logout, account deletion and the duress wipe.
//

import Foundation
import CoreData
import GRPCCore
#if canImport(UIKit)
import UIKit
#endif

extension AuthViewModel {
    func logout() {
        Task { [weak self] in
            guard let self else { return }
            if AuthSessionManager.shared.sessionToken != nil {
                // Nothing is announced to contacts: the device leaves the account's directory,
                // and a peer's next message to it is answered by nobody. Until 2026-09-27 an
                // END_SESSION went to every contact here.
                do {
                    try await AuthServiceClient.shared.logout()
                } catch {
                    Log.error("Logout API call failed: \(error.localizedDescription)", category: "Auth")
                }
            }
            await MainActor.run {
                self.performLocalSignOut()
            }
            await MediaSendCache.shared.clear()
        }
    }

    /// Wipes the session, the device identity and every local trace of the account
    /// (`LocalDataWipe`), so ContentView routes back to onboarding.
    /// Safe to call when the server logout RPC is unavailable (revoked/inactive device).
    func performLocalSignOut() {
        cancelTimeouts()
        MessageStreamManager.shared.disconnect()
        AuthSessionManager.shared.clearSession()
        StealthSenderService.shared.clearCertCache()   // drop the old identity's sealed-sender cert
        CryptoManager.shared.deleteAllCryptoKeys()
        KeychainManager.shared.deleteDeviceKeys()
        KeychainManager.shared.deleteOtpks()
        KeychainManager.shared.deleteAllContactRequestMappings()
        UserDefaults.standard.removeObject(forKey: "recovery_is_setup")
        UserDefaults.standard.removeObject(forKey: "recovery_banner_dismissed")
        UserDefaults.standard.removeObject(forKey: "cr_pending_nav_user_ids")
        OrientationStore.reset()
        // Signing out leaves nothing of the account on this device: the transcript used to stay
        // for a later seed recovery of the same account. History moves between devices now, and
        // a device that was signed out — or removed — must not keep reading as the account.
        LocalDataWipe.run(reason: "sign_out")
        deviceLinkPhase = .idle
        deviceKeysUnavailable = false
        deviceDeregistered = false
        isAuthenticated = false
        currentUserId = nil
        hasRegisteredDeviceKeys = false
        Log.info("Local sign-out complete — routing to onboarding", category: "Auth")
    }

    /// Signs out of ALL devices simultaneously (invalidates all refresh tokens server-side),
    /// then performs local logout. Use when a device may have been compromised.
    func logoutAllDevices() {
        Task { [weak self] in
            guard let self else { return }
            if AuthSessionManager.shared.sessionToken != nil {
                do {
                    try await AuthServiceClient.shared.logout(allDevices: true)
                    Log.info("Signed out of all devices", category: "Auth")
                } catch {
                    Log.error("logoutAllDevices API call failed: \(error.localizedDescription)", category: "Auth")
                }
            }
            await MainActor.run {
                self.performLocalSignOut()
            }
        }
    }
    
    func deleteAccount() {
        self.isLoading = true
        
        Log.info("Requesting account deletion", category: "AuthViewModel")
        
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.deleteAccountWithDeviceSignature()
                await MainActor.run { self.handleDeleteAccountSuccess() }
            } catch {
                Log.error("deleteAccount raw error: \(error)", category: "AuthViewModel")
                await MainActor.run {
                    self.cancelTimeouts()
                    self.isLoading = false
                    self.deleteAccountFailed = true
                    ErrorRouter.shared.report(Self.friendlyDeleteError(error))
                }
            }
        }
    }

    private static func friendlyDeleteError(_ error: Error) -> AppError {
        // Unimplemented (code 12): the server endpoint is not there yet.
        if let rpc = error as? RPCError, rpc.code == .unimplemented {
            return .said(UserText("delete_account_not_available"))
        }
        // The reason is our own sentence for the failure, never the error's words.
        return .said(UserText("delete_account_failed", AppError.from(error).userText.resolved))
    }

    /// Deletes all local data without contacting the server.
    /// Used as a fallback when the server is unreachable (e.g. blocked by censorship).
    func deleteAccountLocally() {
        Log.info("Deleting account locally only (server unreachable)", category: "AuthViewModel")
        handleDeleteAccountSuccess()
    }

    /// Called when duress PIN is entered on the lock screen.
    /// Immediately wipes all local data; attempts server deletion best-effort in background.
    func triggerDuressWipe() {
        Log.info("Duress PIN triggered — initiating silent wipe", category: "AuthViewModel")
        Task { [weak self] in
            guard self != nil else { return }
            do {
                _ = try await UserServiceClient.shared.deleteAccount(
                    confirmation: "DELETE",
                    reason: "duress"
                )
            } catch {
                Log.error("Duress wipe: remote delete failed: \(error.localizedDescription)", category: "AuthViewModel")
            }
        }
        handleDeleteAccountSuccess()
    }

    private func deleteAccountWithDeviceSignature() async throws {
        let response = try await UserServiceClient.shared.deleteAccount(
            confirmation: "DELETE",
            reason: "user_requested"
        )
        guard response.success else {
            throw NSError(domain: "AuthViewModel", code: 3, userInfo: [NSLocalizedDescriptionKey: response.message])
        }
    }
}
