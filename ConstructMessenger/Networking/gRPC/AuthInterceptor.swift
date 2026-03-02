import Foundation
import GRPCCore

/// Injects Bearer token and x-user-id into gRPC metadata for every RPC call.
/// Skips auth for unauthenticated RPCs (challenge, register, authenticate).

struct AuthInterceptor: ClientInterceptor {
    /// RPCs that do not require authentication
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

        if Self.unauthenticatedMethods.contains(methodName) {
            Log.debug("🔓 gRPC \(methodName) — unauthenticated (no token required)", category: "gRPC")
        } else {
            let (token, userId) = await MainActor.run {
                (SessionManager.shared.sessionToken, SessionManager.shared.currentUserId)
            }

            let tokenStatus = token != nil ? "present(\(token!.prefix(8))…)" : "⚠️ MISSING"
            let userStatus  = userId ?? "⚠️ MISSING"
            Log.debug("🔐 gRPC \(methodName) — token=\(tokenStatus) userId=\(userStatus)", category: "gRPC")

            if let token {
                request.metadata.addString("Bearer \(token)", forKey: "authorization")
            } else {
                Log.error("❌ gRPC \(methodName) called without auth token — request will likely fail", category: "gRPC")
            }
            if let userId {
                request.metadata.addString(userId, forKey: "x-user-id")
            }
        }

        do {
            let response = try await next(request, context)
            return response
        } catch {
            if let rpcError = error as? RPCError {
                Log.error("❌ gRPC \(methodName) failed: code=\(rpcError.code) message=\"\(rpcError.message)\"", category: "gRPC")
            } else {
                Log.error("❌ gRPC \(methodName) failed: \(error)", category: "gRPC")
            }
            throw error
        }
    }
}
