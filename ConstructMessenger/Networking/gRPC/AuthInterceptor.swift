import Foundation
import GRPCCore

/// Injects the Bearer auth token into gRPC metadata for every RPC call.
/// Skips auth for unauthenticated RPCs (challenge, register, authenticate).

struct AuthInterceptor: ClientInterceptor {
    /// RPCs that do not require authentication
    private static let unauthenticatedMethods: Set<String> = [
        "GetPowChallenge",
        "RegisterDevice",
        "AuthenticateDevice",
        "RefreshToken"
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
            let token = await MainActor.run { SessionManager.shared.sessionToken }
            if let token {
                request.metadata.addString("Bearer \(token)", forKey: "authorization")
            }
        }

        return try await next(request, context)
    }
}
