//
//  DeviceKeyAvailability.swift
//  Construct Messenger
//
//  Whether this device still holds its identity — and, crucially, the difference between
//  "it does not" and "we could not read it".
//
//  INCIDENT (2026-08-09, build 593): a user's account reset itself. The app launched, decided
//  the device had no keys, and routed to onboarding; registering there minted a new identity
//  over the old one.
//
//  `KeychainManager.load(forKey:)` returned `Data?` and collapsed every non-success `OSStatus`
//  into `nil` — `errSecItemNotFound` (never registered) and `errSecInteractionNotAllowed`
//  (device locked, keys are there but unreadable) were the same value. Device keys are stored
//  `AfterFirstUnlock`, so before the first unlock after a reboot they are *legitimately*
//  unreadable.
//
//  The bitter part: the correct handler already existed. `AuthViewModel.handleLostDeviceKeys`
//  does not wipe anything, shows a recovery screen (retry / seed phrase / new account), and its
//  comment names "device locked at launch" explicitly. But it is only reachable when a session
//  token exists. Without one, the flow fell through to `DeviceAuthCoordinator`, whose
//  `guard let … else { return .noDeviceKeys }` sent the user to onboarding. Two branches, one
//  question, opposite answers — and the destructive one had no idea it was destroying anything.
//  Nothing had to be deleted for the identity to be lost: `hasRegisteredDeviceKeys = false` is
//  enough.
//

import Foundation

enum DeviceKeyAvailability: Equatable {
    /// Both keys read back. Normal.
    case present
    /// Both keys are genuinely absent. Onboarding is the correct destination.
    case absent
    /// At least one key could not be read, or only some of them exist. The identity may be
    /// intact — recovery screen, never onboarding.
    case unreadable

    /// Resolve the pair of Keychain reads into one answer.
    ///
    /// Two rules, both chosen because the failure modes are not symmetric. Sending a user with
    /// intact keys to onboarding destroys their identity and (before the ownership gate) handed
    /// their contacts to a stranger. Sending a user with no keys to a recovery screen costs one
    /// tap. So:
    ///
    ///   * any unreadable read wins — never claim absence on the strength of a failed read;
    ///   * a partial state (one key present, the other absent) is `unreadable` too. It is not a
    ///     clean install, and re-registering over a half-present identity is the worse mistake.
    static func resolve(deviceId: KeychainRead, signingKey: KeychainRead) -> DeviceKeyAvailability {
        let reads = [deviceId, signingKey]

        if reads.allSatisfy(\.isFound) { return .present }
        if reads.allSatisfy(\.isAbsent) { return .absent }
        // Everything else — any unreadable read, or a partial state — lands here. An explicit
        // `contains(where: \.isUnreadable)` guard stood above these two and was removed: it was
        // unreachable-by-effect, no mutation could kill it, and a line no test can fail is the
        // same defect as a test that cannot fail.
        return .unreadable
    }
}
