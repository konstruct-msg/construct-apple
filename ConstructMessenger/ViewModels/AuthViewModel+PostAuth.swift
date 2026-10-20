//
//  AuthViewModel+PostAuth.swift
//  Construct Messenger
//
//  Part of AuthViewModel: post-auth maintenance: OTPK/Kyber/hybrid publishing, MLS refresh, push registration,
//  the own-device-set report and the once-per-process app-launch announce.
//

import Foundation
import CoreData
import GRPCCore
#if canImport(UIKit)
import UIKit
#endif

extension AuthViewModel {
    func runPostAuthMaintenance(userId: String, reason: String) {
        Task { [weak self] in
            guard self != nil else { return }
            let deviceId = KeychainManager.shared.loadDeviceID() ?? ""
            guard !deviceId.isEmpty else {
                Log.error("Post-auth key maintenance skipped — deviceId unavailable (\(reason))", category: "Auth")
                return
            }
            #if os(macOS)
            Log.debug("Post-auth key maintenance (\(reason), Desktop direct core path)", category: "Auth")
            #endif
            // Kyber first: its first publish carries the hybrid identity in the same request, which
            // is what lets the server check the hybrid signature on every Kyber key. The hybrid
            // publish after it then finds nothing left to do, or re-attaches the classic SPK's
            // signature after a rotation.
            await KyberPrekeyService.publishIfNeeded(deviceId: deviceId)
            Self.announceAppLaunchedOnce()
            await HybridIdentityService.publishIfNeeded(deviceId: deviceId)
            await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
            await Self.logOwnDeviceSet(userId: userId, thisDeviceId: deviceId)
        }
        Task { [weak self] in
            guard self != nil else { return }
            await ServerKeyManager.shared.prefetch()
        }
        BlockSyncService.shared.sync()
    }

    private static var appLaunchAnnounced = false

    /// Tell the core the app has launched, once per process: it answers with the launch timers,
    /// among them `pq_upgrade_sweep`, which reopens pre-v2 classical sessions as PQXDH v2 15 s later.
    ///
    /// Nothing sent this event until 2026-09-25 — the enum case existed only in the logging
    /// switch — so the upgrade sweep never ran on iOS and every classical session stayed
    /// classical. Here and not at core init because the reopen it leads to fetches the peer's
    /// bundle, which needs an authenticated transport; once, because re-auth runs this path again
    /// and the core would re-arm the timers each time.
    private static func announceAppLaunchedOnce() {
        guard !appLaunchAnnounced else { return }
        do {
            let actions = try CryptoManager.shared.handleOrchestratorEvent(.appLaunched, tag: "post_auth")
            appLaunchAnnounced = true
            SessionActionExecutor.shared.executeOffRouter(actions, site: "app_launched")
        } catch {
            Log.error("AppLaunched not delivered to the core: \(error)", category: "Auth")
        }
    }

    /// State the account's device set, once per authenticated session, before anything needs it.
    ///
    /// Until 2026-09-02 nothing did. The composition of the set was visible only indirectly, in
    /// `SESSION_STATE[responder_candidates]`, and only when a session failed to initialise — so a
    /// run set up as one device per account, which was actually two because a Desktop unlinked a
    /// week earlier still counted as active, read as a clean single-device run in every log line
    /// it produced. Every message was being sent twice and every sibling copy dropped, and the
    /// only way to learn that was to reverse-trace message ids across two devices' logs.
    ///
    /// A powered-off device is indistinguishable from a live one here, deliberately: this reports
    /// what the server holds, which is the set every sender will fan out to. It is the same fetch
    /// the receive path already makes on a cache miss, so it also warms that cache at launch
    /// rather than on the first message that needs it, and it never consumes a one-time pre-key.
    private static func logOwnDeviceSet(userId: String, thisDeviceId: String) async {
        // Retried, because post-auth maintenance runs while the transport is still choosing a
        // path. On 2026-09-02 the first attempt landed in the same second as the direct→VEIL
        // switch and came back `unavailable: "Stream unexpectedly closed."` — along with the OTPK
        // replenish, the MLS package refresh, the push token registration and a peer bundle
        // fetch. Every one of those retries; this did not, so the only thing it produced was an
        // ERROR about a perfectly healthy account, and the line it exists to print never appeared
        // for the rest of the session. Same ladder as the push registration next to it.
        var devices: [DeviceBundleData] = []
        for attempt in 1...3 {
            devices = await MultiDeviceSendCoordinator.shared.refreshOwnDevices(myUserId: userId)
            if !devices.isEmpty { break }
            guard attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
        }
        guard !devices.isEmpty else {
            // Not "no devices" — the fetch failed, and `refreshOwnDevices` has already said why.
            Log.error("DEVICE_SET: \(userId.prefix(8))… — set unknown after 3 attempts", category: "Auth")
            return
        }
        let listed = devices
            .map { "\($0.deviceId.prefix(8))…\($0.deviceId == thisDeviceId ? "(this)" : "")" }
            .joined(separator: ", ")
        Log.info("DEVICE_SET: \(userId.prefix(8))… has \(devices.count) device(s): \(listed)", category: "Auth")

        // The set is known here and nowhere earlier, and it is the only thing that invalidates a
        // published metadata blob — in both directions: a device added has no copy until we
        // re-seal, and a device removed can still read until we do. `publish` is a no-op when the
        // set has not moved.
        await DeviceMetadataService.publish(myUserId: userId, reason: "device_set_known")
        if !devices.contains(where: { $0.deviceId == thisDeviceId }) {
            // We are authenticated as a device the key service does not list. Every peer fans out
            // to a set that excludes us, so nothing addressed per-device can arrive.
            Log.error(
                "DEVICE_SET: this device \(thisDeviceId.prefix(8))… is NOT in its own account's active set",
                category: "Auth"
            )
        }
    }
}
