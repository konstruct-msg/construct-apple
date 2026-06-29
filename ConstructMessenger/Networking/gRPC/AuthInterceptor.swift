import Foundation
import GRPCCore

/// Injects Bearer token, x-user-id, and x-device-id into gRPC metadata for every RPC call.
/// Skips auth for unauthenticated RPCs (challenge, register, authenticate).

struct AuthInterceptor: ClientInterceptor {
    /// RPCs that do not require authentication.
    /// Must match Envoy's `jwt_authn` filter rules in `construct-server/ops/envoy.docker.yaml` —
    /// only routes that bypass the JWT provider there can omit auth here. Public services
    /// in Envoy: `AuthService`, `DeviceService`, `/.well-known/*`, `/health`, plus the
    /// specific `UserService/CheckUsernameAvailability` path (carve-out for onboarding —
    /// pre-registration users have no JWT but must check username availability). Adding
    /// an RPC here that Envoy still gates surfaces as `Jwt is missing` to the user.
    private static let unauthenticatedMethods: Set<String> = [
        "GetPowChallenge",
        "RegisterDevice",
        "AuthenticateDevice",
        "RefreshToken",
        "CheckUsernameAvailability"
    ]

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        let methodName = context.descriptor.method
        var request = request

        if !Self.unauthenticatedMethods.contains(methodName) {
            // Read from the lock-protected cache — no actor hop needed.
            let snap = GRPCAuthCache.shared.snapshot
            guard let token = snap.token, snap.isValid else {
                throw RPCError(code: .unauthenticated, message: "Session token expired — please log in")
            }
            request.metadata.addString("Bearer \(token)", forKey: "authorization")
            if let userId = snap.userId {
                request.metadata.addString(userId, forKey: "x-user-id")
            } else {
                // Rare recovery path: userId missing from cache, extract from JWT claim.
                if let recovered = TokenUtils.extractUserId(from: token) {
                    await MainActor.run { AuthSessionManager.shared.updateUserId(recovered) }
                    request.metadata.addString(recovered, forKey: "x-user-id")
                } else {
                    throw RPCError(code: .unauthenticated, message: "x-user-id unavailable — userId missing from session")
                }
            }
            if let deviceId = snap.deviceId {
                request.metadata.addString(deviceId, forKey: "x-device-id")
            }
        }

        return try await next(request, context)
    }
}
