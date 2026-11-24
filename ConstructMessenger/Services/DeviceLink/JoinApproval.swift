//
//  JoinApproval.swift
//  ConstructMessenger
//
//  The new device's wait in Flow B: the phone approves our QR, then we sign in with the key we
//  asked to join with. `decisions/a-joining-device-signs-in-with-its-own-key.md`.
//

import Foundation
import GRPCCore

@MainActor
final class JoinApproval {

    /// Approved, and then refused at sign-in in a way that would repeat: a clock out by minutes, a
    /// wrong key.
    struct SignInRefused: Error {
        let underlying: any Error
    }

    private let isApproved: () async throws -> Bool
    private let signIn: () async throws -> AuthServiceClient.ConfirmLinkResult
    /// The server forgets an approval sooner than the QR expires; we do not.
    private var approved = false

    init(
        isApproved: @escaping () async throws -> Bool,
        signIn: @escaping () async throws -> AuthServiceClient.ConfirmLinkResult
    ) {
        self.isApproved = isApproved
        self.signIn = signIn
    }

    /// Nil while pending. Throws `DeviceLinkError` or `SignInRefused` when the join is over, and
    /// anything else when a later poll may get past it.
    func poll() async throws -> AuthServiceClient.ConfirmLinkResult? {
        if !approved {
            approved = try await isApproved()
        }
        guard approved else { return nil }
        do {
            return try await signIn()
        } catch let error as RPCError where Self.refusals.contains(error.code) {
            throw SignInRefused(underlying: error)
        }
    }

    private static let refusals: [RPCError.Code] = [.invalidArgument, .unauthenticated, .permissionDenied]
}
