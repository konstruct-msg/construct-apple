//
//  BlockSync.swift
//  ConstructMessenger
//
//  A block lives in two places: the local flag, which drops what arrives, and the server's
//  `user_blocks` row, which refuses a call. Each was sent to the server once, best-effort, and a
//  lost unblock left the row for good — the person shown as unblocked here could not be called
//  ("Call not allowed", TODO 170, 2026-10-18). Now the wanted state is queued per person and
//  resent until the server answers, and the server's list is read back after the queue drains.
//

import Foundation
import GRPCCore

enum BlockSync {
    struct Intent: Codable, Equatable {
        var blocked: Bool
        var reason: String?
    }

    private static let key = "block_sync_pending"

    /// The latest wish for `userId` replaces an earlier one still waiting.
    static func record(_ userId: String, blocked: Bool, reason: String? = nil, in defaults: UserDefaults = .standard) {
        var all = pending(in: defaults)
        all[userId] = Intent(blocked: blocked, reason: reason)
        save(all, in: defaults)
    }

    static func pending(in defaults: UserDefaults = .standard) -> [String: Intent] {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: Intent].self, from: data) else { return [:] }
        return all
    }

    /// Only the wish that was sent: one recorded while it was in flight stays for the next pass.
    static func confirm(_ userId: String, _ sent: Intent, in defaults: UserDefaults = .standard) {
        var all = pending(in: defaults)
        guard all[userId] == sent else { return }
        all[userId] = nil
        save(all, in: defaults)
    }

    private static func save(_ all: [String: Intent], in defaults: UserDefaults) {
        if all.isEmpty { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    enum Disposition: Equatable { case retry, drop }

    /// The path failing, or a session being renewed, is tried again; a server's refusal (an
    /// account that is gone, an id it rejects) would be refused every time.
    static func disposition(after error: Error) -> Disposition {
        if let rpc = error as? RPCError, rpc.code == .unauthenticated { return .retry }
        return SendFailure.isRetryableTransport(error) ? .retry : .drop
    }

    /// Server rows this device does not show: made visible here, so the person sees what the
    /// server enforces and can lift it. Never unblocked blindly — the row is also what carries a
    /// block across a reinstall. A person with a wish still queued is left to the queue.
    static func toAdopt(
        serverBlocked: [String],
        pending: [String: Intent],
        isBlockedHere: (String) -> Bool
    ) -> [String] {
        serverBlocked.filter { pending[$0] == nil && !isBlockedHere($0) }
    }
}

/// Runs the queue, then reads the server's list. One pass at a time; a request during a pass
/// starts another after it, so a wish recorded mid-pass is never overtaken by the read-back.
@MainActor
final class BlockSyncService {
    static let shared = BlockSyncService()
    private init() {}

    private var running: Task<Void, Never>?
    private var again = false
    /// Waits between passes that found the path down; the foreground starts a new run anyway.
    private static let backoff: [Duration] = [.seconds(2), .seconds(10), .seconds(30), .seconds(120)]

    /// Records the wish and sends it. The caller has already set the local flag.
    ///
    /// The person's own block, on this device, so the intake key they hold is retired. A block
    /// adopted from the server's list (`readBack`) does not come through here and does not rotate.
    func request(_ userId: String, blocked: Bool, reason: String? = nil) {
        BlockSync.record(userId, blocked: blocked, reason: reason)
        sync()
        if blocked {
            Task { await IntakeCredentialService.shared.rotate(dropping: userId) }
        }
    }

    func sync() {
        guard running == nil else { again = true; return }
        running = Task { [weak self] in
            await self?.pass()
            guard let self else { return }
            self.running = nil
            if self.again { self.again = false; self.sync() }
        }
    }

    private func pass() async {
        for attempt in 0...Self.backoff.count {
            guard let failure = await flush() else {
                await readBack()
                return
            }
            guard attempt < Self.backoff.count else { break }
            if failure is VeilTunnelNotUp {
                guard await VeilTunnelWait.untilRouted() else { break }
            } else {
                try? await Task.sleep(for: Self.backoff[attempt])
            }
        }
        Log.info("Block sync: \(BlockSync.pending().count) still queued — next foreground", category: "BlockSync")
    }

    /// Nil when the queue is empty; otherwise the failure that stopped it.
    private func flush() async -> Error? {
        for (userId, intent) in BlockSync.pending() {
            do {
                if intent.blocked {
                    _ = try await UserServiceClient.shared.blockUser(userId: userId, reason: intent.reason)
                } else {
                    _ = try await UserServiceClient.shared.unblockUser(userId: userId)
                }
                BlockSync.confirm(userId, intent)
            } catch {
                switch BlockSync.disposition(after: error) {
                case .retry:
                    return error
                case .drop:
                    Log.error("Block sync refused for \(userId.prefix(8))… (blocked=\(intent.blocked)): \(error)", category: "BlockSync")
                    BlockSync.confirm(userId, intent)
                }
            }
        }
        return nil
    }

    private func readBack() async {
        let serverBlocked: [String]
        do {
            serverBlocked = try await UserServiceClient.shared.getBlockedUserIds()
        } catch {
            Log.info("Block sync: server list not read (\(type(of: error)))", category: "BlockSync")
            return
        }
        let contacts = LocalRepositories.contacts
        let adopt = BlockSync.toAdopt(
            serverBlocked: serverBlocked,
            pending: BlockSync.pending(),
            isBlockedHere: { (try? contacts.isBlocked($0)) == true }
        )
        var shown = 0
        for userId in adopt where (try? contacts.setBlocked(userId, true)) == true { shown += 1 }
        if shown > 0 {
            Log.info("Block sync: \(shown) server block(s) were not shown here — now shown", category: "BlockSync")
        }
    }
}
