//
//  ChatSessionManager.swift
//  Construct Messenger
//

import Foundation
import CoreData

@MainActor
final class ChatSessionManager {

    // MARK: - Dependencies

    /// The account the open chat is with.
    private let peerId: String
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

    init(peerId: String) {
        self.peerId = peerId
        self.sessionInitService = SessionInitializationService.shared
    }

    func setViewModel(_ vm: ChatViewModel) {
        self.viewModel = vm
    }

    // MARK: - Session readiness

    func checkExistingSession() {
        let userId = peerId
        let ready = CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId)
        viewModel?.isSessionReady = ready
        if ready {
            Log.info("Session already exists for user: \(userId)", category: "ChatViewModel")
        } else {
            Log.debug("No session yet for user: \(userId)", category: "ChatViewModel")
        }
    }

    func fetchRecipientPublicKey() {
        let userId = peerId
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
        // Ask the crypto core whether a session exists (authoritative; `isSessionReady` is
        // per-ViewModel view state that resets on each chat open), and leave username backfill
        // to the profile path, which owns it.
        let sessionExists = CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId)
        if sessionExists { viewModel?.isSessionReady = true }
        let identityKeyKnown = recipientBundle != nil
            || StealthSenderService.recipientIdentityKey(recipientId: userId) != nil
        guard case .fetch(let consumeOneTimePrekey) = Self.bundleFetchOnOpen(
            sessionExists: sessionExists, identityKeyKnown: identityKeyKnown
        ) else { return }

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
                    consumeOneTimePrekey: consumeOneTimePrekey
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

    enum BundleFetchOnOpen: Equatable {
        case skip
        case fetch(consumeOneTimePrekey: Bool)
    }

    /// What opening a chat fetches. Never a one-time pre-key: `getPreKeyBundle` with
    /// `consume` makes the server delete one of the peer's OTPKs and hand it out, and this
    /// bundle runs no X3DH — it warms the identity key stealth sealing needs and readies the
    /// composer. The session is made at send, by `initializeSessionProactively`, which fetches
    /// its own consuming bundle right before it uses it.
    ///
    /// Skip the network only when a session exists and the identity key is known: under
    /// stealth-on a missing key is fail-closed (`StealthDowngradeBlocked` → queue + retry), so
    /// a contact we only ever answered still needs the fetch.
    ///
    /// Until 2026-10-13 a chat with no session fetched with `consume: true` on every open, and
    /// the bundle went into `recipientBundle`, which session creation never reads — so each
    /// open spent one of the peer's keys for nothing and the first send spent another. A Mac
    /// linked with history has no sessions and spent six of one peer's keys in minutes. The
    /// fix of 2026-07-28 (10 fetches in 5.5 minutes, all with a session) covered only the
    /// branch where a session exists.
    nonisolated static func bundleFetchOnOpen(sessionExists: Bool, identityKeyKnown: Bool) -> BundleFetchOnOpen {
        if sessionExists && identityKeyKnown { return .skip }
        return .fetch(consumeOneTimePrekey: false)
    }

    private func handlePublicKeyBundle(_ data: PublicKeyBundleData) {
        Log.debug("Received publicKeyBundle for userId: \(data.userId), peer: \(peerId), match: \(data.userId == peerId)", category: "ChatViewModel")
        guard data.userId == peerId else { return }
        self.recipientBundle = (data.identityPublic, data.signedPrekeyPublic, data.signature, data.verifyingKey)
        publicKeyFetchTimer?.invalidate()
        publicKeyFetchTimer = nil
        viewModel?.isSessionReady = true
        if CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: data.userId) {
            Log.info("SESSION_STATE[bundle_fetched_session_exists]: session already established for \(data.userId.prefix(8))…", category: "ChatViewModel")
        } else {
            Log.info("SESSION_STATE[bundle_cached]: bundle ready for \(data.userId.prefix(8))…, session will be created on first send", category: "ChatViewModel")
        }
        onSessionReady?(data.userId)
    }

    func initializeSessionProactively(userId: String) async {
        viewModel?.isInitializingSession = true
        var succeeded = false
        await sessionInitService.initializeSessionProactively(
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
        onSessionReady?(userId)
    }

    // `sendSessionInitPing` stood here until 2026-09-27: a control message sent on every fresh
    // session so that `msgNum=0` — then the only message a session could open from — would not be
    // user content. Every message of the first flight carries the handshake header now and any of
    // them opens (`decisions/sessions-renew-by-sending.md`), so the first one may be the user's.

}
