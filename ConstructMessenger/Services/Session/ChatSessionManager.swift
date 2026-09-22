//
//  ChatSessionManager.swift
//  Construct Messenger
//

import Foundation
import CoreData

@MainActor
final class ChatSessionManager {

    // MARK: - Dependencies

    private let chat: Chat
    private let sessionInitService: SessionInitializationService
    private weak var viewModel: ChatViewModel?

    // MARK: - State

    private var recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data)?
    private var publicKeyFetchTimer: Timer?
    private let publicKeyFetchTimeout: TimeInterval = 10.0

    // MARK: - Callbacks (userId, reason-string)

    var onSessionReady: ((String) -> Void)?
    var onSessionFailed: ((String, String) -> Void)?

    // MARK: - Init

    init(chat: Chat) {
        self.chat = chat
        self.sessionInitService = SessionInitializationService.shared
    }

    func setViewModel(_ vm: ChatViewModel) {
        self.viewModel = vm
    }

    // MARK: - Session readiness

    func checkExistingSession() {
        guard let userId = chat.otherUser?.id else { return }
        let ready = CryptoManager.shared.hasSession(for: userId)
        viewModel?.isSessionReady = ready
        if ready {
            Log.info("Session already exists for user: \(userId)", category: "ChatViewModel")
        } else {
            Log.debug("No session yet for user: \(userId)", category: "ChatViewModel")
        }
    }

    func fetchRecipientPublicKey() {
        guard let userId = chat.otherUser?.id else {
            Log.error("Cannot fetch recipient public key: chat.otherUser?.id is nil", category: "ChatViewModel")
            return
        }
        guard let currentUserId = AuthSessionManager.shared.currentUserId else {
            Log.error("Cannot fetch recipient public key: currentUserId is nil", category: "ChatViewModel")
            return
        }
        Log.debug("Fetching public key for userId: \(userId), currentUserId: \(currentUserId)", category: "ChatViewModel")
        if userId == currentUserId {
            ErrorRouter.shared.report(.validation(.selfSend))
            Log.debug("Blocked attempt to initialize session with self", category: "ChatViewModel")
            return
        }
        // Whether this fetch is allowed to burn one of the peer's one-time pre-keys.
        //
        // `getPreKeyBundle` is destructive: the server DELETEs an OTPK and hands it out.
        // `onViewAppear` calls this on every chat open, so an unnecessary consuming fetch
        // drains a real contact's pool — device logs showed 10 fetches in 5.5 minutes, every
        // one landing on "session already established". That is what emptied the peer's pool
        // and left new inbound sessions running X3DH with no one-time pre-key.
        //
        // The old guard was `isSessionReady == true && hasUsername`, which conflated key
        // material with a *profile* concern: a contact whose username we never stored slipped
        // through on every open, and since a key bundle carries no username the condition
        // could never become true — a permanent loop. Ask the crypto core instead
        // (authoritative; `isSessionReady` is per-ViewModel view state that resets on each
        // chat open) and leave username backfill to the profile path, which owns it.
        let sessionExists = CryptoManager.shared.hasSession(for: userId)
        if sessionExists {
            viewModel?.isSessionReady = true
            // Skip the network entirely only when the identity key is already available —
            // stealth sealing needs it, and under stealth-on a missing key is fail-closed
            // (`StealthDowngradeBlocked` → queue + retry), so silently skipping would stall
            // sends for a contact we only ever responded to. Otherwise fall through to a
            // NON-consuming fetch: same long-lived material, no OTPK burned.
            if recipientBundle != nil || StealthSenderService.recipientIdentityKey(
                recipientId: userId,
                context: PersistenceController.shared.container.viewContext
            ) != nil {
                return
            }
            Log.debug("Session exists but no cached identity key for \(userId.prefix(8))… — non-consuming bundle fetch", category: "ChatViewModel")
        }

        publicKeyFetchTimer?.invalidate()
        publicKeyFetchTimer = Timer.scheduledTimer(withTimeInterval: publicKeyFetchTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel?.isSessionReady == false else { return }
                Log.error("Timeout waiting for public key bundle from server", category: "ChatViewModel")
                ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                    self?.fetchRecipientPublicKey()
                })
                self.viewModel?.isSessionReady = false
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let publicKeyBundle = try await sessionInitService.fetchPublicKeyWithRetry(
                    userId: userId,
                    consumeOneTimePrekey: !sessionExists
                )
                publicKeyFetchTimer?.invalidate()
                publicKeyFetchTimer = nil
                handlePublicKeyBundle(publicKeyBundle)
            } catch {
                publicKeyFetchTimer?.invalidate()
                publicKeyFetchTimer = nil
                Log.error("Failed to fetch public key via gRPC after retries: \(error.localizedDescription)", category: "ChatViewModel")
                ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                    self?.fetchRecipientPublicKey()
                })
                viewModel?.isSessionReady = false
            }
        }
    }

    private func handlePublicKeyBundle(_ data: PublicKeyBundleData) {
        Log.debug("Received publicKeyBundle for userId: \(data.userId), chat.otherUser?.id: \(chat.otherUser?.id ?? "nil"), match: \(data.userId == chat.otherUser?.id)", category: "ChatViewModel")
        guard data.userId == chat.otherUser?.id else { return }
        self.recipientBundle = (data.identityPublic, data.signedPrekeyPublic, data.signature, data.verifyingKey)
        publicKeyFetchTimer?.invalidate()
        publicKeyFetchTimer = nil
        viewModel?.isSessionReady = true
        if CryptoManager.shared.hasSession(for: data.userId) {
            Log.info("SESSION_STATE[bundle_fetched_session_exists]: session already established for \(data.userId.prefix(8))…", category: "ChatViewModel")
        } else {
            Log.info("SESSION_STATE[bundle_cached]: bundle ready for \(data.userId.prefix(8))…, session will be created on first send", category: "ChatViewModel")
        }
        onSessionReady?(data.userId)
    }

    func initializeSessionProactively(userId: String) async {
        viewModel?.isInitializingSession = true
        var succeeded = false
        let opened = await sessionInitService.initializeSessionProactively(
            userId: userId,
            // Reached from opening a conversation and from sending into one; both are a person
            // waiting on this session, which is what the flag means.
            hasOutboundWork: true,
            onSuccess: { [weak self] in
                guard let self else { return }
                succeeded = true
                self.viewModel?.isSessionReady = true
                self.viewModel?.isInitializingSession = false
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.viewModel?.isInitializingSession = false
                if case CryptoManagerError.coreNotInitialized = error {
                    Log.error("coreNotInitialized in initializeSessionProactively — OrchestratorCore missing", category: "ChatViewModel")
                    ErrorRouter.shared.report(error)
                    self.onSessionFailed?(userId, error.userFacingMessage)
                    return
                }
                ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                    self?.fetchRecipientPublicKey()
                })
                self.onSessionFailed?(userId, error.userFacingMessage)
            }
        )
        guard succeeded else { return }
        // The ping is about the ratchets this run built, so it is addressed to them. Empty means
        // the sessions were already in place and nothing new claimed `msgNum=0`; then the ping
        // goes to every device we hold a session with, which is what it has always done.
        await sendSessionInitPing(to: userId, devices: opened)
        onSessionReady?(userId)
    }

    /// Post-init ping (msgNum=0) announcing our fresh ratchets to the peer.
    ///
    /// **One per ratchet, through the one sender.** The ping exists to keep `msgNum=0` off user
    /// content: the first message on a fresh session is the X3DH carrier, and a carrier the peer
    /// discards costs nothing while a user message lost there is a user message lost. A session is
    /// a ratchet between two devices, so a peer with two devices has two `msgNum=0` slots and,
    /// until 2026-09-22, one of them was taken by the ping and the other by whatever the user
    /// typed — the account-shaped send resolved to the pinned device and the sibling never got
    /// one.
    ///
    /// Sent through `OutboundMessagePipeline` as a control rather than by hand, which is what
    /// gives each copy the device tag its recipient recognises it by. Two untagged copies of one
    /// `msgNum=0` message are worse than one: the device that cannot open the other's copy takes
    /// the recovery path, and for `msgNum == 0` that path fetches a key bundle over the network
    /// (`DeviceDeliveryPlan`).
    ///
    /// Still fail-closed under stealth, and still skippable: the pipeline refuses to downgrade a
    /// sealed control, and a refused ping only means the peer establishes from the X3DH carrier
    /// plus the tie-break watchdog, as it did before this existed.
    ///
    /// - Parameter devices: the ratchets to announce. Empty means "every device we hold a session
    ///   with" — the pipeline's own answer.
    func sendSessionInitPing(to userId: String, devices: [String] = []) async {
        // A SESSION_RESET_INIT is in flight for this peer and owns msgNum=0 on the (now shared,
        // post-coalescing) session. The ping exists only to keep msgNum=0 off user content, so
        // once the SRI has that slot it is redundant — and sending it would put a second X3DH
        // carrier on the wire that the peer can only discard.
        //
        // Asked of the account, because that is what the tracker is keyed by. Moving it to the
        // device belongs with the rest of the confirm gate — `session-is-one-state-machine`.
        guard !SessionConfirmationTracker.shared.isPending(userId) else {
            Log.info("SESSION_STATE[init_ping_skipped]: SESSION_RESET_INIT owns msgNum=0 for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }
        guard let frameType = SessionControlCodec.frameContentType(for: .ping) else { return }
        let pingId = UUID().uuidString.lowercased()
        let nonce = UUID().uuidString
        let payload = SessionControlCodec.encodePayload(op: .ping, nonce: nonce)

        do {
            // The ping's type rides in KNST byte 5, inside the ciphertext; the server is told
            // nothing. Outer envelope only — the sealed path declares `.generic`.
            let report = try await OutboundMessagePipeline.shared.sendToRecipientDevices(
                plan: .whole(payload, contentType: frameType, messageId: UUID(uuidString: pingId) ?? UUID()),
                baseMessageId: pingId,
                senderId: myId,
                recipientId: userId,
                timestamp: UInt64(Date().timeIntervalSince1970),
                kind: .control,
                onlyDevices: devices.isEmpty ? nil : devices
            )
            Log.info(
                "SESSION_STATE[init_ping_sent]: msgNum=0 ping sent to \(report.accepted.count) device(s) of \(userId.prefix(8))… — user messages follow as msgNum=1+",
                category: "SessionInit"
            )
        } catch let blocked as StealthDowngradeBlocked {
            Log.error("SESSION_STATE[init_ping_downgrade_blocked]: \(blocked.reason) — ping skipped (never sent identified under stealth)", category: "SessionInit")
        } catch {
            Log.error("SESSION_STATE[init_ping_failed]: \(error.localizedDescription) for \(userId.prefix(8))… — user messages will be sent anyway", category: "SessionInit")
        }
    }
}
