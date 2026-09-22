import Foundation
import CoreData
import GRPCCore
import os.log

/// Errors specific to the session-init layer (distinct from CryptoManagerError).
enum SessionError: Error, LocalizedError, ApplicationLayerError {
    /// Server returned a bundle whose SPK rotation epoch is older than the last
    /// seen epoch for this contact — possible replay attack.
    case staleSPKBundle(epoch: UInt32, knownEpoch: UInt32)
    /// Peer's SPK is older than the Rust core's staleness limit.
    /// The peer must open their app to trigger SPK rotation before a session can be established.
    case peerSPKStale(ageDays: Double)
    /// Peer is a PQ device but their bundle has `kyberSpkRotationEpoch == 0`,
    /// meaning they never uploaded a Kyber SPK. Session init must be refused to
    /// avoid silently downgrading to classical-only key agreement.
    case kyberEpochRequired
    /// The envelope is not an X3DH / PQXDH handshake — feeding it to
    /// `initReceivingSession` can only fail (AEAD / unknown PQ epoch) and then
    /// clear the pending queue, including any real handshake behind it.
    case notAHandshakeCarrier

    /// The server answered `notFound` for this peer's prekey bundle. Terminal, not transient:
    /// no amount of retrying makes a deleted account exist. See `VanishedPeerStore`.
    case peerNotFound

    /// The core said not to open a session right now — `plan_initiation` answered `Wait` or
    /// `YieldToPeer`. Not a failure: nothing went wrong and nothing needs retrying. It is
    /// delivered through `onFailure` because that is the only channel a caller awaiting a
    /// continuation can be resumed on, and a caller that treats every error as terminal would
    /// otherwise hang.
    case initiationDeferred(decision: String)

    var errorDescription: String? {
        switch self {
        case .staleSPKBundle(let epoch, let knownEpoch):
            return "SPK bundle replay: received epoch \(epoch) ≤ known epoch \(knownEpoch)"
        case .peerSPKStale(let days):
            return "Contact's encryption keys are \(String(format: "%.0f", days)) days old and need to be refreshed — ask them to open the app"
        case .kyberEpochRequired:
            return "Contact's post-quantum keys are incomplete — ask them to update the app"
        case .notAHandshakeCarrier:
            return "Incoming message is not a session handshake"
        case .peerNotFound:
            return "This account no longer exists"
        case .initiationDeferred(let decision):
            return "Session init deferred by the core: \(decision)"
        }
    }
}

/// Service responsible for session initialization with retry logic and queue management.
/// Singleton: the pending KEM ciphertexts / OTPK IDs must be visible across all
/// call-sites (SessionCoordinator prewarm, ChatViewModel send, auto-resend, etc.).
@MainActor
class SessionInitializationService {

    static let shared = SessionInitializationService()
    private init() {}

    // MARK: - Public Methods
    
    /// Fetch public key bundle with exponential backoff retry.
    ///
    /// - Parameter consumeOneTimePrekey: pass `true` only when this bundle will actually run
    ///   X3DH. `false` fetches the same long-lived material (identity / verifying / signed
    ///   pre-key) without burning one of the peer's one-time pre-keys — use it when the
    ///   session already exists and we only need to warm the identity key.
    func fetchPublicKeyWithRetry(
        userId: String,
        deviceId: String? = nil,
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        consumeOneTimePrekey: Bool
    ) async throws -> PublicKeyBundleData {
        var lastError: Error?
        var delay = initialDelay
        var attempt = 0
        var throttledWaits = 0

        while attempt < maxAttempts {
            attempt += 1
            do {
                Log.info("SESSION_STATE[fetch_bundle_attempt_\(attempt)]: userId=\(userId.prefix(8))..., deviceId=\(deviceId?.prefix(8) ?? "nil")..., consumeOtpk=\(consumeOneTimePrekey)", category: "SessionInit")
                let keyBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId, deviceId: deviceId, consumeOneTimePrekey: consumeOneTimePrekey)
                Log.info("SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., hasVerifyingKey=\(!keyBundle.verifyingKey.isEmpty)", category: "SessionInit")
                return keyBundle
            } catch {
                lastError = error

                // A rate limit is not a transport failure, and the fast ladder is the wrong answer
                // to it. The key service allows `BUNDLE_RATE_LIMIT_PER_MIN` requests per minute
                // and refuses the rest for the remainder of that window; 1s and 2s land inside it
                // by construction, so all three attempts fail and the caller treats a peer it will
                // be able to reach in under a minute as one it can never reach.
                //
                // Desktop, 2026-09-03, its first minute after linking: ten bundle requests in
                // eighty seconds, then `fetch_bundle_failed` three times in three seconds,
                // `fetch_bundle_exhausted`, `proactive_init_failed`, `watchdog_reinit_fail`. From
                // that point every message from the peer arrived with `flags=end_session` and the
                // session could not be rebuilt, because rebuilding it needs the bundle the limiter
                // was refusing. Nothing was displayed on that device for the rest of the run.
                //
                // So a throttled answer waits out the window instead of spending an attempt on it.
                // Bounded, because a wait long enough to clear the window is long enough that two
                // of them is already the outer limit of what a session init may hold.
                if Self.isRateLimited(error) {
                    guard throttledWaits < Self.maxThrottledWaits else {
                        Log.error("SESSION_STATE[fetch_bundle_throttled_out]: userId=\(userId.prefix(8))… — still rate-limited after \(throttledWaits) window wait(s)", category: "SessionInit")
                        break
                    }
                    throttledWaits += 1
                    attempt -= 1  // a refusal to answer is not an answer; it costs no attempt
                    Log.info("SESSION_STATE[fetch_bundle_throttled]: userId=\(userId.prefix(8))… — waiting \(Int(Self.throttleWindowWait))s for the limiter window (wait \(throttledWaits)/\(Self.maxThrottledWaits))", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(Self.throttleWindowWait * 1_000_000_000))
                    continue
                }

                Log.error("SESSION_STATE[fetch_bundle_failed]: attempt=\(attempt)/\(maxAttempts), error=\(error) (\(type(of: error)))", category: "SessionInit")

                if attempt < maxAttempts {
                    Log.info("Retrying public key fetch in \(delay)s...", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2  // Exponential backoff: 1s, 2s, 4s
                }
            }
        }
        
        Log.error("SESSION_STATE[fetch_bundle_exhausted]: userId=\(userId.prefix(8))..., allAttemptsFailed", category: "SessionInit")
        throw lastError ?? NetworkError.connectionFailed
    }

    /// The key service refusing to answer *for now*, as opposed to failing to answer.
    static func isRateLimited(_ error: Error) -> Bool {
        (error as? RPCError)?.code == .resourceExhausted
    }

    /// How long to wait out a bundle rate-limit window.
    ///
    /// The limiter's window is 60s and starts on the first request in it, so the remaining time
    /// when we are refused is anywhere in `(0, 60]` and the server tells us nothing about it —
    /// `resource_exhausted` carries a message and no `retry-after`. Two thirds of the window is
    /// the point where waiting again is cheaper than waiting longer up front: it clears most
    /// refusals in one wait, and `maxThrottledWaits` covers the rest.
    static let throttleWindowWait: TimeInterval = 40

    /// Two waits, because a session init that has held for eighty seconds should hand the
    /// decision back rather than keep holding.
    static let maxThrottledWaits = 2
    
    /// Initialize a session with a recipient using their public key bundle
    func initializeSession(
        userId: String,
        bundle: PublicKeyBundleData,
        deleteExisting: Bool = true,
        allowStale: Bool = false
    ) throws -> Void {
        // Proactively delete stale session if requested
        if deleteExisting {
            if CryptoManager.shared.hasSession(for: userId) {
                CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
                Log.info("Proactively deleted any existing session for \(userId) before initialization.", category: "SessionInit")
            }
        }

        // Epoch replay-attack check: reject bundles where the server's monotonic
        // rotation counter has not advanced beyond what we last saw for this contact.
        // (Skip when epoch == 0, which means the server hasn't migrated yet.)
        if bundle.spkRotationEpoch > 0 {
            let knownEpoch = KeychainManager.shared.loadSpkEpoch(for: userId)
            if bundle.spkRotationEpoch < knownEpoch {
                Log.error("SESSION_STATE[spk_replay_rejected]: epoch=\(bundle.spkRotationEpoch) < known=\(knownEpoch) for \(userId.prefix(8))… — possible SPK replay attack", category: "SessionInit")
                throw SessionError.staleSPKBundle(epoch: bundle.spkRotationEpoch, knownEpoch: knownEpoch)
            }
            KeychainManager.shared.saveSpkEpoch(bundle.spkRotationEpoch, for: userId)
        }

        // PQ_HYBRID bundles (suiteId == 2) must have a non-zero Kyber SPK epoch.
        // epoch == 0 means the peer never uploaded a Kyber SPK; refuse to proceed
        // rather than silently falling back to classical-only key agreement.
        if bundle.suiteId == 2 && bundle.kyberSpkRotationEpoch == 0 {
            Log.error("SESSION_STATE[kyber_epoch_missing]: suiteId=2 but kyberSpkRotationEpoch==0 for \(userId.prefix(8))… — refusing PQ session init", category: "SessionInit")
            throw SessionError.kyberEpochRequired
        }

        let bundleWithSuite = (
            identityPublic: bundle.identityPublic,
            signedPrekeyPublic: bundle.signedPrekeyPublic,
            signature: bundle.signature,
            verifyingKey: bundle.verifyingKey,
            suiteId: String(bundle.suiteId)
        )

        var otpkPublic = bundle.oneTimePreKeyPublic
        var otpkId = bundle.oneTimePreKeyId

        // 3-DH re-init: a prior END_SESSION from this peer signalled it could not reproduce our
        // 4-DH one-time-prekey (otpk-session-init-deadlock lever L2). Drop the classic OTPK and
        // do 3-DH, which the responder can always reproduce from identity + signed prekey —
        // instead of handing it another OTPK it will also reject and looping. Consumed once; a
        // later clean init uses 4-DH again. (The Kyber OTPK is a separate store and is left as-is.)
        let hintPending = SessionReinitHintStore.shared.consumeThreeDHReinit(for: userId)
        if SessionReducer.nextInitDHMode(forceThreeDHHintPending: hintPending) == .threeDH {
            Log.info("SESSION_STATE[force_3dh_reinit]: \(userId.prefix(8))… — dropping one-time-prekey, using 3-DH", category: "SessionInit")
            otpkPublic = Data()
            otpkId = 0
        }

        do {
            PerformanceMetrics.shared.start(.sessionInitStart, label: String(userId.prefix(8)))
            try CryptoManager.shared.initializeSession(
                for: userId,
                recipientBundle: bundleWithSuite,
                oneTimePreKeyPublic: otpkPublic,
                oneTimePreKeyId: otpkId,
                kyberPreKeyPublic: bundle.kyberPreKeyPublic,
                kyberOneTimePreKeyPublic: bundle.kyberOneTimePreKeyPublic,
                kyberOneTimePreKeyId: bundle.kyberOneTimePreKeyId,
                spkUploadedAt: bundle.spkUploadedAt,
                spkRotationEpoch: bundle.spkRotationEpoch,
                kyberSpkUploadedAt: bundle.kyberSpkUploadedAt,
                kyberSpkRotationEpoch: bundle.kyberSpkRotationEpoch,
                supportsPqRatchet: bundle.supportsPqRatchet ?? false,
                allowStale: allowStale
            )
            PerformanceMetrics.shared.end(.sessionInitStart, endEvent: .sessionInitEnd, label: String(userId.prefix(8)))
            // A session now exists — date it here, where it is created, not where it is later
            // confirmed. `markActive` (the peer's `session_ready`) used to be the INITIATOR's only
            // writer, which left every freshly built session undatable until the peer answered:
            // build 585 destroyed a session built at 10:54:07 with an END_SESSION stamped 10:54:03,
            // because the stale-check read `established=nil`. See `SessionEstablishment`.
            //
            // Every INITIATOR path funnels through this method, so one call covers prewarm,
            // proactive init, re-init after END_SESSION, multi-device and profile share.
            SessionEstablishment.record(for: userId)
            // Track at-risk state: a degraded (stale-SPK) init is authentic but should be
            // re-keyed once the peer rotates; a clean init clears any prior at-risk flag.
            if allowStale {
                KeychainManager.shared.saveSessionAtRiskFlag(for: userId)
                Log.info("Session initialized as INITIATOR (degraded/at-risk) for \(userId)", category: "SessionInit")
            } else {
                KeychainManager.shared.deleteSessionAtRiskFlag(for: userId)
                Log.info("Session initialized as INITIATOR for \(userId)", category: "SessionInit")
            }
        } catch let sessionError as SessionError {
            throw sessionError
        } catch {
            Log.error("Session init failed for \(userId): \(error)", category: "SessionInit")
            Log.error("   bundle.suiteId=\(bundle.suiteId), identityPublic.len=\(bundle.identityPublic.count), signedPrekeyPublic.len=\(bundle.signedPrekeyPublic.count)", category: "SessionInit")
            throw error
        }
    }
    
    /// Proactively initialize session for a user (fetch bundle + initialize).
    ///
    /// When the peer's SPK is stale (`peerSPKStale`), the peer may have just come
    /// online and rotated their keys. The server may not yet reflect the new
    /// `spk_uploaded_at`. In that case we wait `staleSPKRetryDelay` seconds and retry
    /// up to `staleSPKMaxRetries` times.
    ///
    /// **Degrade path**: if `ageDays >= staleSPKFastFailDays` (30.25d = 6h past the Rust 30-day
    /// limit), the peer has clearly not been online recently — waiting is pointless, so we go
    /// straight to a degraded (at-risk) init instead of burning 2 × 60 s on retries.
    /// Outcome of one proactive-init run, shared with every coalesced caller.
    private enum ProactiveInitOutcome {
        /// The devices sessions were opened with — each derived from the bundle's identity key,
        /// so each is a ratchet's own name and the address the handshake controls about that
        /// session must carry. Empty only under the test override, which opens nothing.
        ///
        /// A **list**, because an account is a set of devices and an init that names one of them
        /// is an init that leaves the rest dark until they write first. See
        /// `decisions/a-peer-is-a-set-of-devices.md`.
        case success(devices: [String])
        case failure(Error)
    }

    /// In-flight proactive inits, keyed by **account**. `@MainActor` makes lookup-then-insert
    /// atomic, so two concurrent callers can never both start a run.
    ///
    /// Stays account-keyed while step 1 of `session-is-one-state-machine` moved `sessionPhases`
    /// to `SessionScope`, and the reason is not oversight: **a single-flight key must be stable
    /// for the lifetime of the flight, and this one's scope is not.** At first contact
    /// `SessionScope.forAccount` is `.peer(account)`; the bundle fetch inside `performProactiveInit`
    /// is what writes `User.knownIdentityKey` (`KeyServiceClient`), so from that moment the same
    /// account resolves to `.device(pinned)`. A late joiner arriving after the pin would compute
    /// the device scope, miss the entry filed under the peer scope, and start a second run —
    /// burning a second OTPK and replacing the first session, which is the 2026-07-31 divergence
    /// this map exists to prevent.
    ///
    /// What unblocks it is the run naming its target device up front instead of resolving
    /// `contactId(forPeer:)` inside — step 6 of the same decision. Until then the account key is
    /// the correct one, because today one INITIATOR run targets exactly one pinned device and the
    /// two keys are 1:1.
    private var proactiveInitTasks: [String: Task<ProactiveInitOutcome, Never>] = [:]

    /// Whether the peer's own session init is in our hands — received and not yet completed.
    ///
    /// Injected rather than read, because the evidence lives in `MessageRouter.pendingQueue` and
    /// this service does not own it. `SessionCoordinator.configure` supplies it; until it does,
    /// the answer is `false`, which is the same answer as "we have seen nothing from them" and is
    /// therefore safe rather than merely convenient.
    var peerInitInFlight: ((String) -> Bool)?

    #if DEBUG
    /// Test seam: substitutes the init run so the coalescing wrapper can be exercised without
    /// the network. Returns `true` for success. Nil in production.
    var proactiveInitOverrideForTests: ((String) async -> Bool)?
    #endif

    /// Establish a session as INITIATOR, coalescing concurrent callers per peer.
    ///
    /// Single-flight is mandatory, not an optimisation. Two runs each fetch a bundle with
    /// `consumeOneTimePrekey: true` (burning two of the peer's OTPKs) and each call
    /// `initializeSession(deleteExisting: true)`, so the second silently replaces the first's
    /// session. The X3DH carriers already dispatched for run #1 (SESSION_RESET_INIT) then
    /// reference a ratchet we no longer hold, while our own messages continue on run #2 —
    /// the peer establishes from one and receives on the other, and diverges on the very next
    /// message. Observed 2026-07-31: `initiator_announce` (END_SESSION received) and
    /// `queue_message` (user typed) started runs 1s apart and forced one guaranteed heal cycle.
    ///
    /// Callers are **coalesced, not skipped**: a late joiner awaits the in-flight run and then
    /// receives the same outcome through its own callbacks. Skipping would strand its queued
    /// messages, since `onSuccess` is what flushes them.
    /// - Parameter hasOutboundWork: whether something is actually waiting to go to this peer — a
    ///   typed message, a queued one, a handshake we owe. No default on purpose: the one call site
    ///   that answers `false` is the one that caused the 2026-09-04 outage, and a default would
    ///   let the next call site inherit an answer nobody chose.
    /// Returns the devices sessions were opened with — empty when none was. A caller that then
    /// speaks for a session — SESSION_RESET_INIT, `session_ready` — addresses **each** of them:
    /// the announcement is about a ratchet, and there is one ratchet per device.
    ///
    /// Until 2026-09-22 this returned one device and there was one to return: the run fetched a
    /// single bundle, which the key server answers with one device of the account, so an account
    /// with two devices got one INITIATOR session and its sibling stayed dark until it wrote to
    /// us first.
    @discardableResult
    func initializeSessionProactively(
        userId: String,
        hasOutboundWork: Bool,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) async -> [String] {
        // Asked here, before the bundle fetch, because the fetch is what spends the peer's
        // one-time prekey. Asking after it would answer a question that has already cost what it
        // was meant to save.
        let decision = planInitiation(context: InitiationContext(
            myDeviceId: KeychainManager.shared.loadDeviceID() ?? "",
            // The peer's pinned device, or nothing at first contact — the core takes an
            // unnameable peer as "cannot rank", not as "cannot write to".
            peerDeviceId: SessionAddressing.contactId(forPeer: userId) ?? "",
            ourInitInFlight: proactiveInitTasks[userId] != nil,
            peerInitInFlight: peerInitInFlight?(userId) ?? false,
            haveOutboundWork: hasOutboundWork
        ))
        switch decision {
        case .initiate, .joinInFlight:
            break  // both continue below; `joinInFlight` is the coalescing branch
        case .wait, .yieldToPeer:
            Log.info(
                "SESSION_STATE[initiation_deferred]: \(decision) for \(userId.prefix(8))… — outboundWork=\(hasOutboundWork), peerInit=\(peerInitInFlight?(userId) ?? false)",
                category: "SessionInit"
            )
            onFailure(SessionError.initiationDeferred(decision: "\(decision)"))
            return []
        }

        let outcome: ProactiveInitOutcome
        if let inFlight = proactiveInitTasks[userId] {
            Log.info("SESSION_STATE[proactive_init_coalesced]: joining in-flight init for \(userId.prefix(8))…", category: "SessionInit")
            outcome = await inFlight.value
        } else {
            let task = Task { [weak self] () -> ProactiveInitOutcome in
                guard let self else { return .failure(CryptoManagerError.coreNotInitialized) }
                #if DEBUG
                if let override = self.proactiveInitOverrideForTests {
                    return await override(userId) ? .success(devices: []) : .failure(CryptoManagerError.coreNotInitialized)
                }
                #endif
                return await self.performProactiveInit(userId: userId, hasOutboundWork: hasOutboundWork)
            }
            proactiveInitTasks[userId] = task
            outcome = await task.value
            proactiveInitTasks[userId] = nil
        }

        switch outcome {
        case .success(let devices):
            onSuccess()
            return devices
        case .failure(let error):
            onFailure(error)
            return []
        }
    }

    /// One device of the peer, and the bundle a session with it opens from.
    private struct InitTarget {
        let deviceId: String
        let bundle: PublicKeyBundleData
    }

    /// What a run does about one device of the account.
    enum InitAction: Equatable {
        /// No session: open one.
        case open
        /// A session is there and this is the device the caller's reason is about.
        case replace
        /// A session is there and nothing said it was broken.
        case leave
    }

    /// Whether a proactive init touches this device, and whether it tears down what is there.
    ///
    /// **The one remaining privilege, stated rather than implicit.** No caller names a device —
    /// they say "re-establish with this person" — so the device the account resolves to is the one
    /// a heal is taken to be about, and it keeps the replace-and-reopen behaviour it has always
    /// had. Every other device is only ever **added**: a session with a sibling is not torn down
    /// by a decision taken about another device, which is the rule the 2026-09-22 reset cut
    /// established on the receive side and the same rule here.
    ///
    /// Naming the device in the call removes the asymmetry, and that is the machine's job —
    /// `decisions/session-is-one-state-machine.md`.
    nonisolated static func initAction(device: String, resolvedDevice: String?, hasSession: Bool) -> InitAction {
        guard hasSession else { return .open }
        return device == resolvedDevice ? .replace : .leave
    }

    /// What one device's init did.
    private enum DeviceInitResult {
        case opened
        /// Nothing to do, or the core said not now — neither is a failure.
        case skipped(String)
        /// The core refused the bundle: the peer's signed pre-key is older than it allows.
        case stale(days: Double)
        case failed(Error)
    }

    /// Every device of `userId` the key server will hand a bundle for, each with its own.
    ///
    /// Plural, because an account is a set of devices: `getPreKeyBundle` (singular) answers with
    /// **one** device chosen by the server, and building an account's sessions from it opens one
    /// and leaves the rest dark. It is kept as the fallback — a narrowed answer, or a server that
    /// cannot answer plurally, then degrades to what this did before rather than to nothing.
    ///
    /// The plural fetch is also what writes `PeerDevice` (`KeyServiceClient` →
    /// `SessionAddressing.reconcileDevices`), so an init is a moment the device set is learned.
    private func initTargets(userId: String) async throws -> [InitTarget] {
        do {
            // Consuming, because a run that reaches a device with no session runs X3DH with it
            // and X3DH is what spends a one-time pre-key. The server spends one per device it
            // answers for, so a heal of a peer whose sibling is already open pays one pre-key it
            // does not use. That is the price of one request instead of one per device, and the
            // ladder below does the opposite on a retry, where the waste would repeat.
            let devices = try await KeyServiceClient.shared.getPreKeyBundles(
                userId: userId, consumeOneTimePrekey: true
            )
            if !devices.isEmpty {
                return devices.map { InitTarget(deviceId: $0.deviceId, bundle: $0.bundle) }
            }
            Log.info(
                "SESSION_STATE[init_targets_empty]: key server named no device for \(userId.prefix(8))… — asking for one",
                category: "SessionInit"
            )
        } catch let rpc as RPCError where rpc.code == .notFound {
            // Answered, not failed. Asking again through the singular path would spend a second
            // request to be told the same thing — see `fetchPublicKeyWithRetry`.
            VanishedPeerStore.shared.markVanished(userId)
            throw SessionError.peerNotFound
        } catch {
            Log.info(
                "SESSION_STATE[init_targets_fallback]: bundles for \(userId.prefix(8))… unavailable (\(error.localizedDescription)) — falling back to one device",
                category: "SessionInit"
            )
        }

        let bundle = try await fetchPublicKeyWithRetry(userId: userId, consumeOneTimePrekey: true)
        guard let device = SessionAddressing.cryptoIdentity(ofIdentityKey: bundle.identityPublic) else {
            throw CryptoManagerError.sessionNotFound
        }
        return [InitTarget(deviceId: device, bundle: bundle)]
    }

    /// Fresh bundles for the devices a stale signed pre-key sent back round the ladder.
    ///
    /// Asked one device at a time, unlike the first pass: the plural fetch spends a one-time
    /// pre-key for **every** device it answers for, and on a retry all but these already have
    /// their session. A peer's pre-key pool is not large — a hundred uploaded at link time, and
    /// they have been observed diverging from the server's count — so a retry pays for what it
    /// retries and nothing else.
    private func retryTargets(userId: String, devices: Set<String>) async -> [InitTarget] {
        var targets: [InitTarget] = []
        for device in devices.sorted() {
            guard let bundle = try? await fetchPublicKeyWithRetry(
                userId: userId, deviceId: device, consumeOneTimePrekey: true
            ) else { continue }
            targets.append(InitTarget(deviceId: device, bundle: bundle))
        }
        return targets
    }

    /// Open a session with one device, or say why not.
    ///
    /// **Which device is replaced and which is only added.** A session already held is left alone
    /// unless it is the one the account currently resolves to — the device today's callers mean
    /// when they say "re-establish with this person", since none of them names a device. So a
    /// heal keeps the behaviour it has, and a sibling is never torn down by a decision taken about
    /// another device (the rule the 2026-09-22 reset cut established). Naming the device in the
    /// call is the machine's job: `decisions/session-is-one-state-machine.md`.
    private func initSession(
        with target: InitTarget,
        userId: String,
        resolvedDevice: String?,
        hasOutboundWork: Bool,
        allowStale: Bool
    ) -> DeviceInitResult {
        let action = Self.initAction(
            device: target.deviceId,
            resolvedDevice: resolvedDevice,
            hasSession: CryptoManager.shared.hasSession(for: target.deviceId)
        )
        guard action != .leave else { return .skipped("session exists") }
        let replaces = action == .replace
        // Per device, not per account: the core ranks **this pair** to decide whether opening now
        // walks into a collision, and for a second device the answer can differ from the pinned
        // one's. `peerInitInFlight` is still account-wide — that store cannot say which device
        // sent the init it holds.
        let decision = planInitiation(context: InitiationContext(
            myDeviceId: KeychainManager.shared.loadDeviceID() ?? "",
            peerDeviceId: target.deviceId,
            ourInitInFlight: false,
            peerInitInFlight: peerInitInFlight?(userId) ?? false,
            haveOutboundWork: hasOutboundWork
        ))
        guard decision == .initiate || decision == .joinInFlight else {
            return .skipped("core said \(decision)")
        }

        do {
            try initializeSession(
                userId: target.deviceId,
                bundle: target.bundle,
                deleteExisting: replaces,
                allowStale: allowStale
            )
            return .opened
        } catch SessionError.peerSPKStale(let days) {
            return .stale(days: days)
        } catch {
            return .failed(error)
        }
    }

    /// The actual init run. Never call directly — go through `initializeSessionProactively`
    /// so concurrent callers coalesce onto a single session.
    ///
    /// **One run, N sessions.** Until 2026-09-22 it fetched one bundle and opened one session,
    /// and the account's other devices were reached only after they wrote to us first — the
    /// establishment half of `a-peer-is-a-set-of-devices`.
    private func performProactiveInit(userId: String, hasOutboundWork: Bool) async -> ProactiveInitOutcome {
        Log.info("SESSION_STATE[proactive_init_start]: userId=\(userId.prefix(8))...", category: "SessionInit")

        let staleSPKMaxRetries = 2
        let staleSPKRetryDelay: UInt64 = 60 // seconds
        /// Grace window above the Rust 30-day staleness limit. If the SPK is only ≤ 6 h past
        /// the limit the peer may have just come online and rotated; the server bundle
        /// cache may simply not have propagated yet. Beyond this window the peer has been
        /// offline for a long time and no amount of waiting will help — degrade instead.
        let staleSPKFastFailDays: Double = 30.25

        let resolvedDevice = SessionAddressing.contactId(forPeer: userId)
        var opened: [String] = []
        /// A device we already hold a session with and left alone. Not an opening, and not a
        /// failure either: the caller's `onSuccess` is what flushes a queue, and a run that
        /// found every session already in place must not report that nothing happened.
        var heldAlready = false
        var lastError: Error?
        /// Devices whose bundle the core refused as stale and that a fresher answer may fix.
        /// Empty on the first pass, where every device is tried.
        var retryOnly: Set<String> = []

        for attempt in 0...staleSPKMaxRetries {
            if attempt > 0 {
                Log.info("SESSION_STATE[stale_spk_retry_\(attempt)]: waiting \(staleSPKRetryDelay)s for peer SPK rotation to propagate — userId=\(userId.prefix(8))…, devices=\(retryOnly.count)", category: "SessionInit")
                try? await Task.sleep(nanoseconds: staleSPKRetryDelay * 1_000_000_000)
                guard !Task.isCancelled else { break }
            }

            let targets: [InitTarget]
            if attempt == 0 {
                do {
                    targets = try await initTargets(userId: userId)
                } catch {
                    lastError = error
                    break
                }
            } else {
                targets = await retryTargets(userId: userId, devices: retryOnly)
                guard !targets.isEmpty else { break }
            }

            var stale: [(target: InitTarget, days: Double)] = []
            for target in targets where attempt == 0 || retryOnly.contains(target.deviceId) {
                guard !opened.contains(target.deviceId) else { continue }
                switch initSession(
                    with: target, userId: userId, resolvedDevice: resolvedDevice,
                    hasOutboundWork: hasOutboundWork, allowStale: false
                ) {
                case .opened:
                    opened.append(target.deviceId)
                case .skipped(let why):
                    heldAlready = heldAlready || CryptoManager.shared.hasSession(for: target.deviceId)
                    Log.info("SESSION_STATE[proactive_init_skipped]: \(target.deviceId.prefix(8))… — \(why)", category: "SessionInit")
                case .stale(let days):
                    stale.append((target, days))
                case .failed(let error):
                    Log.error("SESSION_STATE[proactive_init_device_failed]: \(target.deviceId.prefix(8))… — \(error.localizedDescription)", category: "SessionInit")
                    lastError = error
                }
            }

            // Everything that could open is open. What is left is a stale signed pre-key, which
            // has two answers and they are told apart by how stale: barely past the limit means
            // the peer may have just rotated and the server's cache has not caught up, so wait;
            // well past it means the peer has been away and waiting changes nothing, so open a
            // degraded (at-risk) session rather than dead-ending. See `stale-peer-reachability`.
            let hopeless = stale.filter { $0.days >= staleSPKFastFailDays }
            let waitable = stale.filter { $0.days < staleSPKFastFailDays }
            let outOfAttempts = attempt == staleSPKMaxRetries
            for entry in hopeless + (outOfAttempts ? waitable : []) {
                Log.error("SESSION_STATE[stale_spk_degraded_init]: \(entry.target.deviceId.prefix(8))… SPK is \(String(format: "%.1f", entry.days))d old — initiating degraded (at-risk) session", category: "SessionInit")
                switch initSession(
                    with: entry.target, userId: userId, resolvedDevice: resolvedDevice,
                    hasOutboundWork: hasOutboundWork, allowStale: true
                ) {
                case .opened:
                    opened.append(entry.target.deviceId)
                case .skipped(let why):
                    Log.info("SESSION_STATE[degraded_init_skipped]: \(entry.target.deviceId.prefix(8))… — \(why)", category: "SessionInit")
                case .stale(let days):
                    lastError = SessionError.peerSPKStale(ageDays: days)
                case .failed(let error):
                    Log.error("SESSION_STATE[degraded_init_failed]: \(error.localizedDescription) for \(entry.target.deviceId.prefix(8))…", category: "SessionInit")
                    lastError = error
                }
            }

            guard !waitable.isEmpty, !outOfAttempts else { break }
            retryOnly = Set(waitable.map(\.target.deviceId))
            lastError = SessionError.peerSPKStale(ageDays: waitable[0].days)
        }

        guard opened.isEmpty, !heldAlready else {
            Log.info(
                "SESSION_STATE[proactive_init_success]: userId=\(userId.prefix(8))… opened=\(opened.map { $0.prefix(8) }.joined(separator: ",")) held=\(heldAlready)",
                category: "SessionInit"
            )
            return .success(devices: opened)
        }

        let finalError = lastError ?? NetworkError.connectionFailed
        Log.error("SESSION_STATE[proactive_init_failed]: userId=\(userId.prefix(8))..., error=\(finalError.localizedDescription)", category: "SessionInit")
        return .failure(finalError)
    }

    // MARK: - At-risk session auto-upgrade (Phase 2)

    /// SPK age below which we consider a peer to have come back online and rotated, so an at-risk
    /// (degraded) session can be safely re-keyed to a fresh one. A peer who came back online
    /// force-rotates (8-day client threshold), so a genuinely-returned peer is well under this.
    /// Comfortably under the Rust 30-day strict limit so the subsequent strict `initializeSession`
    /// cannot itself throw `peerSPKStale`.
    private let atRiskUpgradeFreshnessDays: Double = 9.0
    /// Minimum spacing between upgrade attempts per contact, so a peer who is still offline doesn't
    /// trigger a bundle fetch on every chat open.
    private let atRiskUpgradeCooldown: TimeInterval = 3600 // 1 hour
    private static let atRiskUpgradeAttemptPrefix = "session.atRiskUpgrade.lastAttempt."

    /// If the session with `userId` was established via a degraded (stale-SPK) init AND the peer has
    /// since rotated their SPK (now fresh), re-key cleanly to a fresh session and clear the at-risk
    /// flag — restoring full forward secrecy. No-op if the session isn't at-risk, the peer is still
    /// stale (keeps the working degraded session — no churn), or we attempted recently. See the
    /// `stale-peer-reachability` decision record (Phase 2).
    func upgradeAtRiskSessionIfPeerFresh(userId: String) async {
        guard KeychainManager.shared.loadSessionAtRiskFlag(for: userId) else { return }
        guard CryptoManager.shared.hasSession(for: userId) else { return }

        // Rate-limit per contact.
        let attemptKey = Self.atRiskUpgradeAttemptPrefix + userId
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: attemptKey)
        if last > 0, now - last < atRiskUpgradeCooldown { return }
        UserDefaults.standard.set(now, forKey: attemptKey)

        do {
            // Freshness PROBE — reads spk_uploaded_at only. Two of the three outcomes below
            // return without re-initialising, so a consuming fetch here would burn one of the
            // peer's one-time pre-keys purely to look at a timestamp. This runs per at-risk
            // contact on every foreground sweep, so it must be non-destructive.
            let probe = try await fetchPublicKeyWithRetry(userId: userId, consumeOneTimePrekey: false)
            // spk_uploaded_at == 0 means a legacy server that doesn't report freshness — we can't
            // tell if the peer rotated, so leave the degraded session in place.
            guard probe.spkUploadedAt > 0 else { return }
            let ageDays = (now - Double(probe.spkUploadedAt)) / 86400.0
            guard ageDays < atRiskUpgradeFreshnessDays else {
                Log.info("SESSION_STATE[at_risk_upgrade_skip]: peer \(userId.prefix(8))… SPK still \(String(format: "%.1f", ageDays))d old — keeping degraded session", category: "SessionInit")
                return
            }

            // Peer is fresh again → clean strict re-init. Re-fetch WITH an OTPK: the probe
            // above deliberately carries none, and a re-key should get full X3DH forward
            // secrecy. Rare and self-throttled (1 h per contact), so the extra RPC is cheap.
            let bundle = try await fetchPublicKeyWithRetry(userId: userId, consumeOneTimePrekey: true)
            try initializeSession(userId: userId, bundle: bundle, deleteExisting: true)
            Log.info("SESSION_STATE[at_risk_upgraded]: re-keyed to fresh session for \(userId.prefix(8))…", category: "SessionInit")
            await MainActor.run {
                NotificationCenter.default.post(name: .sessionAtRiskChanged, object: nil, userInfo: ["userId": userId])
            }
        } catch {
            Log.info("SESSION_STATE[at_risk_upgrade_failed]: \(error.localizedDescription) for \(userId.prefix(8))… — will retry later", category: "SessionInit")
        }
    }

    /// Foreground sweep: try to upgrade every at-risk (degraded-init) session whose peer has since
    /// rotated back to a fresh SPK. Complements the per-chat-open trigger — after the Phase 3B server
    /// wake nudges a dormant peer to rotate (SPK_WAKE_PUSH_SERVER_SPEC), the sender's degraded session
    /// heals on the next foreground instead of only when the user happens to open that specific chat.
    ///
    /// Cheap by construction: only contacts whose at-risk flag is set are checked, and each
    /// `upgradeAtRiskSessionIfPeerFresh` call is self-throttled (1h/contact) and no-ops while the peer
    /// is still stale — so a repeated foreground doesn't churn or burst bundle fetches.
    func upgradeAllAtRiskSessionsOnForeground() async {
        guard AuthSessionManager.shared.isSessionValid, CryptoManager.shared.isInitialized else { return }

        let ctx = PersistenceController.shared.container.viewContext
        let req = User.fetchRequest()
        req.predicate = NSPredicate(format: "isContact == YES")
        let contactIds: [String] = ((try? ctx.fetch(req)) ?? []).map { $0.id }.filter { !$0.isEmpty }

        let atRisk = contactIds.filter { KeychainManager.shared.loadSessionAtRiskFlag(for: $0) }
        guard !atRisk.isEmpty else { return }

        Log.info("SESSION_STATE[at_risk_sweep]: \(atRisk.count) at-risk session(s) on foreground — checking peer freshness", category: "SessionInit")
        for userId in atRisk {
            await upgradeAtRiskSessionIfPeerFresh(userId: userId)
        }
    }
}
