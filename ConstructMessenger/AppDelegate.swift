//
//  AppDelegate.swift
//  Construct Messenger
//
//

import UIKit
import BackgroundTasks

class AppDelegate: NSObject, UIApplicationDelegate {

    // Inject DeepLinkHandler for processing Universal Links
    let deepLinkHandler = DeepLinkHandler()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {

        Log.info("Application did finish launching")

        // Bootstrap the foreground-state tracker now (at launch, while active) so its lifecycle
        // observers are registered before the first background transition. The transport layer
        // reads it off-main to suppress futile VEIL restarts while suspended (see AppActivityState).
        _ = AppActivityState.shared

        // Register UserDefaults defaults — only applies when key has never been set.
        // This makes push notifications and background fetch ON for new installs.
        UserDefaults.standard.register(defaults: [
            "pushNotificationsEnabled": true,
            "backgroundFetchEnabled": true,
            "stt_auto_transcribe": false,
            "stt_engine": "auto",
        ])

        if PreviewDetector.isRunningInPreview {
            return true
        }

        // Bound the outgoing wire-payload store. Its 24h TTL was only ever evaluated when a
        // specific message's key was read back, so payloads for messages that were never retried
        // accumulated without limit — see OutgoingWirePayloadRetention. Off the main thread: it
        // decodes every stored entry, and by the time this matters there are a lot of them.
        DispatchQueue.global(qos: .utility).async {
            OutgoingWirePayloadStore.shared.sweepExpired()

            // Drain message thumbnails out of UserDefaults — 37 MB of JPEG in a 4 MB domain, which
            // is why CFPreferences started refusing writes for everything else living there.
            // See ThumbnailStore. Reads migrate lazily too; this catches the ones nobody opens.
            // Move received media out of Library/Caches, which iOS purges under disk pressure —
            // and the server drops the object 7 days after upload, so a purge on day nine takes
            // the last copy that exists. See MediaManager.mediaDirectory.
            Task { @MainActor in MediaManager.shared.migrateMediaOutOfCaches() }

            let migrated = ThumbnailStore.shared.migrateFromUserDefaults()
            if migrated.keys > 0 {
                Log.info(
                    "ThumbnailStore migration: \(migrated.keys) key(s), \(migrated.bytes / 1024)KB moved to disk",
                    category: "MediaManager"
                )
            }

            #if DEBUG
            // Measured after the sweep and the migration, so the number is what the user carries now.
            UserDefaultsFootprint.logSummary()
            #endif
        }

        // CRITICAL: Register background tasks BEFORE app finishes launching
        // This must be done early in the launch process
        BackgroundFetchManager.shared.registerBackgroundTasks()

        // Check if user has enabled background fetch in settings
        // If enabled, schedule the first background fetch task
        if BackgroundFetchConfig.shouldBeEnabled {
            BackgroundFetchManager.shared.scheduleBackgroundFetch()
            Log.info("Background fetch is enabled, scheduled first task")
        } else {
            Log.info("Background fetch is disabled by user or Low Power Mode")
        }

        // Crash reports, delivered to us rather than through App Store Connect (TODO 40).
        // Subscribed at launch because MetricKit hands over the *previous* run's crash — the
        // later this registers, the more of that window we are not listening for.
        CrashDiagnosticsCollector.shared.start()

        // Initialize local notification manager
        // This ensures it's ready when needed
        _ = LocalNotificationManager.shared
        
        // NEW: Initialize push notification manager
        // This sets up the UNUserNotificationCenter delegate
        _ = PushNotificationManager.shared

        // Calls base: start PushKit VoIP registry (feature-flagged).
        _ = VoIPPushManager.shared
        VoIPPushManager.shared.startIfEnabled()
        _ = CallManager.shared

        // Touch STT service early. This forces WhisperModelManager init which now calls
        // reconcileModels(). This recovers downloaded models that would otherwise look
        // "missing" after an app update (stale absolute paths in UserDefaults, changed
        // container layout, etc.).
        _ = VoiceTranscriptionService.shared.isAvailable

        // NOTE: NetworkReachabilityManager and MessageQueueManager will be initialized
        // lazily when first accessed. This avoids potential circular dependencies
        // and initialization issues at app startup.

        return true
    }
    
    // MARK: - Push Notifications
    
    /// Called when APNs successfully registers device token
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Log.info("Received device token from APNs", category: "Push")
        
        // Register token with backend server
        Task {
            await PushNotificationManager.shared.registerDeviceToken(deviceToken)
        }
    }
    
    /// Called when APNs fails to register device token
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Log.error("Failed to register for remote notifications: \(error)", category: "Push")
        PushNotificationManager.shared.handleRegistrationError(error)
    }

    // MARK: - Silent Push (background wakeup)

    /// Called when a silent push arrives (content-available: 1).
    /// The payload may carry an `activity_type` field for directed actions:
    ///   - "replenish_prekeys" → generate and upload new OTPKs in background
    ///   - (default)           → fetch pending messages and show local notification
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let construct = userInfo["construct"] as? [AnyHashable: Any]
        let activityType = construct?["type"] as? String
        Log.info("Silent push received — activity_type: \(activityType ?? "nil")", category: "Push")
        PushNotificationManager.shared.signalSilentPush()

        if activityType == "replenish_prekeys" {
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        guard let deviceId = KeychainManager.shared.loadDeviceID() else {
                            Log.error("OTPK push: no deviceId in Keychain", category: "Push")
                            return
                        }
                        await OtpkReplenishmentService.replenishForPush(deviceId: deviceId)
                    }
                    group.addTask { try? await Task.sleep(nanoseconds: 27_000_000_000) }
                    await group.next()
                    group.cancelAll()
                }
                completionHandler(.newData)
            }
            return
        }

        if activityType == "republish_hybrid_prekeys" {
            // Server detected our published bundle has a hybrid identity key but no SPK hybrid
            // signature (a rotation whose separate hybrid publish failed). Re-publish now so peers
            // stop hard-rejecting it ("SPK hybrid signature missing"). Force publish (not
            // publishIfNeeded) since the server explicitly flagged the bundle as broken.
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        guard let deviceId = KeychainManager.shared.loadDeviceID() else {
                            Log.error("Hybrid republish push: no deviceId in Keychain", category: "Push")
                            return
                        }
                        do {
                            try await HybridIdentityService.publish(deviceId: deviceId)
                            Log.info("Hybrid republish push: re-published hybrid SPK signatures", category: "Push")
                        } catch {
                            Log.error("Hybrid republish push failed: \(error)", category: "Push")
                        }
                    }
                    group.addTask { try? await Task.sleep(nanoseconds: 27_000_000_000) }
                    await group.next()
                    group.cancelAll()
                }
                completionHandler(.newData)
            }
            return
        }

        if activityType == "rotate_keys" {
            // Stale-peer reachability Phase 3B: a peer fetched our pre-key bundle while our
            // Signed Pre-Key was going stale, so the server woke us to refresh it (see
            // backend/SPK_WAKE_PUSH_SERVER_SPEC.md). Rotate the SPK (no-op if already fresh —
            // e.g. the background maintenance task, Phase 3A, beat us to it) and top up OTPKs so
            // the peer's next bundle fetch gets a fresh bundle and its session init stops
            // degrading to at-risk. Best-effort, bounded to the background push window.
            //
            // INERT until the server emits this activity_type — the SendKeyRotationWake RPC is
            // not built yet (proposed in SPK_WAKE_PUSH_SERVER_SPEC.md). The marker contract is
            // `activity_type = "rotate_keys"`, matching the other key-maintenance wakes above.
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        guard let deviceId = KeychainManager.shared.loadDeviceID() else {
                            Log.error("Key-rotation wake: no deviceId in Keychain", category: "Push")
                            return
                        }
                        await PreKeyRotationService.shared.rotateIfNeeded(deviceId: deviceId)
                        await OtpkReplenishmentService.replenishForPush(deviceId: deviceId)
                    }
                    group.addTask { try? await Task.sleep(nanoseconds: 27_000_000_000) }
                    await group.next()
                    group.cancelAll()
                }
                completionHandler(.newData)
            }
            return
        }

        if activityType == "contact_request_accepted" {
            let requestId = construct?["conversation_id"] as? String
            Log.info("contact_request_accepted push — requestId: \(requestId ?? "nil")", category: "Push")
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        // Creates CoreData contact and appends to pendingNavigationUserIds.
                        // SynapsView picks up navigation on next foreground appearance.
                        await ContactRequestService.shared.checkAndCreateContacts()
                    }
                    group.addTask { try? await Task.sleep(nanoseconds: 27_000_000_000) }
                    await group.next()
                    group.cancelAll()
                }
                completionHandler(.newData)
            }
            return
        }

        // Someone redeemed our invite QR/link — create local contact for call mutuality.
        // conversation_id carries the accepter's ServerUserId (see AcceptInvite server path).
        if activityType == "invite_accepted" {
            let peerUserId = construct?["conversation_id"] as? String
            Log.info("invite_accepted push — peer=\(peerUserId?.prefix(8) ?? "nil")…", category: "Push")
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        if let peerUserId, !peerUserId.isEmpty {
                            _ = await ContactLinkService.shared.handleInviteAccepted(peerUserId: peerUserId)
                        }
                    }
                    group.addTask { try? await Task.sleep(nanoseconds: 27_000_000_000) }
                    await group.next()
                    group.cancelAll()
                }
                completionHandler(.newData)
            }
            return
        }

        if activityType == "contact_request_received" {
            let requestId = construct?["conversation_id"] as? String
            Log.info("contact_request_received push — requestId: \(requestId ?? "nil")", category: "Push")
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        // Refresh inbox + local banner (background) / NC (foreground).
                        await ContactRequestService.shared.handleIncomingRequestPush(
                            requestId: requestId
                        )
                    }
                    group.addTask { try? await Task.sleep(nanoseconds: 27_000_000_000) }
                    await group.next()
                    group.cancelAll()
                }
                completionHandler(.newData)
            }
            return
        }

        // A new_message silent push that lands while the app is foregrounded with a LIVE
        // MessageStream is redundant — the stream already delivered the message — and was the
        // confirmed trigger of a reconnect storm: every incoming message produced a push, and
        // the push-driven fetch churned the stream (~1 reconnect per message, transport-agnostic;
        // device logs showed the push immediately preceding "Starting MessageStream connection"
        // on every cycle). Silent pushes exist to wake a BACKGROUNDED app (or one whose stream is
        // down) to fetch; in the foreground the stream handles it. Skip the fetch in that case.
        //
        // Exception: an incoming call waiting on its SDP. The offer rides this stream, and a
        // zombie "connected" QUIC session hid it for 15 s on 2026-08-22 (7CDE9769) while
        // this skip ate every push that could have pulled it.
        let ignoreSilentPush = MainActor.assumeIsolated {
            shouldIgnoreSilentPush(
                foregroundLiveStream: UIApplication.shared.applicationState == .active
                    && MessageStreamManager.shared.isConnected,
                callNeedsOffer: CallManager.shared.needsOfferPull
            )
        }
        if ignoreSilentPush {
            Log.info("Silent push (\(activityType ?? "?")) ignored — foreground MessageStream is live", category: "Push")
            completionHandler(.noData)
            return
        }

        // FIXME(masque): When MASQUE-over-TCP is implemented, the engine path replaces this.
        // For now the engine never starts on iOS (UDP 443 blocked by OS), so use the
        // legacy BackgroundFetchManager path directly.
        let pushArrivedAt = Date()
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await BackgroundFetchManager.shared.fetchPendingMessagesForSilentPush(
                        pushArrivedAt: pushArrivedAt
                    )
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 27_000_000_000)
                }
                // Complete as soon as either the fetch finishes or the timeout fires.
                await group.next()
                group.cancelAll()
            }
            completionHandler(.newData)
        }
    }

    // MARK: - Universal Links
    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            Log.info("AppDelegate: Not a web browsing activity or no URL")
            return false
        }

        Log.info("AppDelegate: Received Universal Link: \(url.absoluteString)", category: "DeepLink")
        let result = deepLinkHandler.handleURL(url)
        Log.info("AppDelegate: Deep link handling result: \(result)", category: "DeepLink")
        return result
    }
    
    // MARK: - Custom URL Scheme (konstruct://)
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey : Any] = [:]
    ) -> Bool {
        Log.info("AppDelegate: Received URL Scheme: \(url.absoluteString)", category: "DeepLink")
        let result = deepLinkHandler.handleURL(url)
        Log.info("AppDelegate: URL Scheme handling result: \(result)", category: "DeepLink")
        return result
    }

    // MARK: - Scene Lifecycle (iOS 13+)

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    // MARK: - Application Lifecycle

    func applicationWillTerminate(_ application: UIApplication) {
        Log.info("Application will terminate")

        // Cancel all scheduled background tasks if user has disabled them
        let userDefaults = UserDefaults.standard
        let isBackgroundFetchEnabled = userDefaults.bool(forKey: "backgroundFetchEnabled")

        if !isBackgroundFetchEnabled {
            BackgroundFetchManager.shared.cancelAllBackgroundTasks()
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Log.debug("Application did become active")

        // Clear badge when app becomes active
        LocalNotificationManager.shared.clearBadge()

        // Remove all delivered notifications
        LocalNotificationManager.shared.removeAllNotifications()

        // Re-request APNs token on every foreground transition (Apple-recommended).
        application.registerForRemoteNotifications()
        Task { await PushNotificationManager.shared.ensureTokenRegistered() }
        Task { await VoIPPushManager.shared.ensureTokenRegistered() }

        // Proactively exercise sessions that have been silent for 12+ hours.
        Task {
            await SessionActivityTracker.shared.sendStaleSessionHeartbeats()
            SessionActivityTracker.shared.logSessionHealthSummary()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Log.debug("Application did enter background")

        // Persist orchestrator coordination state (ACK cache, session archive index, etc.)
        // so it survives memory eviction. No-op if the crypto core hasn't been loaded yet.
        CryptoManager.shared.saveOrchestratorStateCFE()

        // Ensure background fetch is scheduled if enabled
        if BackgroundFetchConfig.shouldBeEnabled {
            BackgroundFetchManager.shared.scheduleBackgroundFetch()
            // Stale-peer reachability Phase 3A: arm the maintenance BGProcessingTask (background
            // SPK rotation + blind-token top-up + stale-session heartbeats). It was registered but
            // never scheduled, so the maintenance cycle never actually ran.
            BackgroundFetchManager.shared.scheduleMaintenanceTask()
        } else {
            BackgroundFetchManager.shared.cancelAllBackgroundTasks()
        }
    }
}

// MARK: - Notification Names (system notifications only)
// Custom app notifications replaced with @Published properties
