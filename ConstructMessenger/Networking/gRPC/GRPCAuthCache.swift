import Foundation

/// A lock-protected snapshot of the auth credentials needed by `AuthInterceptor`.
///
/// Updated by `SessionManager` on every session state change.
/// Read by `AuthInterceptor` without an actor hop, eliminating the per-RPC MainActor dispatch.
struct AuthSnapshot: Sendable {
    let token: String?
    let userId: String?
    let deviceId: String?
    /// Token expiry from the server. Used to compute `isValid` on every read so expiry is
    /// detected without re-reading UserDefaults.
    let expiresAt: Date?

    /// True when the token is present and has not expired (5-minute buffer).
    var isValid: Bool {
        guard token != nil else { return false }
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(5 * 60) < expiresAt
    }

    static let empty = AuthSnapshot(token: nil, userId: nil, deviceId: nil, expiresAt: nil)
}

/// Thread-safe cache of `AuthSnapshot` used by `AuthInterceptor`.
///
/// All writes come from `SessionManager` (on MainActor, safe to read all properties).
/// All reads come from `AuthInterceptor` (nonisolated gRPC interceptor thread).
final class GRPCAuthCache: Sendable {
    static let shared = GRPCAuthCache()
    private init() {}

    private let _lock = NSLock()
    private nonisolated(unsafe) var _snapshot: AuthSnapshot = .empty

    var snapshot: AuthSnapshot { _lock.withLock { _snapshot } }

    func update(_ snapshot: AuthSnapshot) { _lock.withLock { _snapshot = snapshot } }

    func invalidate() { _lock.withLock { _snapshot = .empty } }
}
