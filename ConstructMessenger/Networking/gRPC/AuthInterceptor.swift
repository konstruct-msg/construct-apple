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

        if !Self.unauthenticatedMethods.contains(methodName) {
            let (token, userId, isValid) = await MainActor.run {
                (SessionManager.shared.sessionToken, SessionManager.shared.currentUserId, SessionManager.shared.isSessionValid)
            }
            guard let token, isValid else {
                throw RPCError(code: .unauthenticated, message: "Session token expired — please log in")
            }
            request.metadata.addString("Bearer \(token)", forKey: "authorization")
            if let userId {
                request.metadata.addString(userId, forKey: "x-user-id")
            }
        }

        return try await next(request, context)
    }
}
