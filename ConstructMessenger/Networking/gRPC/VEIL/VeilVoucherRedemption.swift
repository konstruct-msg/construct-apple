//
//  VeilVoucherRedemption.swift
//  Construct Messenger
//
//  The receiving half of the bootstrap voucher: what has to happen *after*
//  `VeilConfigImporter` has verified a blob and pinned its front.
//
//  Importing is not enough. The pin lands in `VeilLearnedFrontStore`, but the
//  proxy pool is only rebuilt when something pushes a fresh snapshot into the
//  router — and the two paths that did that went through
//  `VeilProxyManager.startIfEnabled()`, which returns early on a device that is
//  not registered yet. That is precisely the case the voucher exists for: B has
//  no account and cannot get one without the tunnel the voucher just granted.
//
//  See decisions/user-vouched-veil-bootstrap.md.
//

import Foundation

@MainActor
enum VeilVoucherRedemption {

    /// Import a scanned or pasted voucher and, on success, make its front reachable.
    /// Returns the relay address on success, for the caller's confirmation copy —
    /// callers that render to the screen must not display it (§"On-screen is a
    /// public surface" in decisions/veil-front-coordinates-are-not-public).
    @discardableResult
    static func redeem(_ text: String) -> Result<String, Error> {
        let result = VeilConfigImporter.importScannedOrPasted(text)
        if case .success = result {
            Task { await armTransport() }
        }
        return result
    }

    /// Push the learned front into the proxy pool and get a probe running on it.
    ///
    /// The snapshot is pushed here rather than left to `startIfNeeded()`, because
    /// that path only reaches `updateRelays` through
    /// `fetchConfigAndEvictIfRemoved()`, which returns early when the manifest
    /// fetch fails — the normal outcome on the censored network a voucher is
    /// redeemed on.
    static func armTransport() async {
        await TransportRouter.shared.updateRelays(ConnectionLoopRelayBridge.snapshotRelays())

        let manager = VeilProxyManager.shared
        guard KeychainManager.shared.isDeviceRegistered() else {
            // Fresh install. `startIfEnabled()` guards on registration and would be a
            // no-op. Force VEIL through the router, which has no such guard.
            //
            // Direct must not be tried first. A clearnet attempt after a successful
            // scan puts the central SNI on the wire of the network that is blocking
            // it — the failure mode [[decisions/silent-transport-ui]] §4 describes.
            // `.on` is the honest setting for someone who has just told us they
            // cannot connect; they can move it back to `.auto` in settings.
            Log.info("VEIL armed from a voucher before registration — forcing mode=on", category: "VEIL")
            manager.mode = .on
            return
        }

        guard manager.mode != .off else { return }
        manager.stop()
        await manager.startIfEnabled()
    }
}
