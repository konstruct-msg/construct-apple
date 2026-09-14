//
//  VeilVoucherViewModel.swift
//  Construct Messenger
//
//  Minting a bootstrap voucher: a short-lived signed blob that gives someone with no
//  way in a working transport, without their build — or any repository, manifest or
//  release binary — ever carrying the front's coordinates.
//
//  See construct-docs decisions/user-vouched-veil-bootstrap.md and
//  decisions/veil-front-coordinates-are-not-public.md.
//

import Foundation
import Observation
import GRPCCore

@MainActor
@Observable
final class VeilVoucherViewModel {

    enum State: Equatable {
        /// Nothing minted yet. The screen opens here and waits for a tap: the server allows
        /// three vouchers per 24h, so opening the screen must not spend one.
        case idle
        case minting
        /// A live voucher.
        ///
        /// `configURI` is for `QRCodeGenerator` and nothing else. It contains the front's
        /// host and pin inside the signed blob, so rendering it — or anything parsed out
        /// of it — puts a private entry point on a screen and, sooner or later, in a
        /// screenshot. The view has no code path that displays it, deliberately.
        case ready(configURI: String, expiresAt: Date)
        case expired
        /// Server quota (3 per 24h): seconds until the oldest voucher ages out.
        case quota(retryAfter: TimeInterval)
        /// The server has the flow switched off. The action hides itself.
        case unavailable
        case failed(String)
    }

    private(set) var state: State = .idle

    // MARK: - Pure helpers (unit-tested)

    /// Pull `retry_after=<seconds>` out of a RESOURCE_EXHAUSTED message.
    /// Returns nil when the server phrased it some other way — the caller then shows the
    /// quota message without a time rather than inventing one.
    static func retryAfterSeconds(from message: String) -> TimeInterval? {
        guard let range = message.range(of: "retry_after=") else { return nil }
        let digits = message[range.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, let secs = TimeInterval(digits) else { return nil }
        return secs
    }

    /// Map an RPC failure to what the user should be told.
    static func state(for error: Error) -> State {
        guard let rpc = error as? RPCError else {
            return .failed(NSLocalizedString("veil_voucher_err_generic", comment: ""))
        }
        switch rpc.code {
        case .unimplemented:
            return .unavailable
        case .resourceExhausted:
            return .quota(retryAfter: retryAfterSeconds(from: rpc.message) ?? 0)
        default:
            return .failed(NSLocalizedString("veil_voucher_err_generic", comment: ""))
        }
    }

    // MARK: - Mint

    func mint() async {
        state = .minting
        do {
            let voucher = try await VeilServiceClient.shared.issueBootstrapVoucher()
            VeilVoucherAvailability.markAvailable()
            let expiresAt = Date(timeIntervalSince1970: TimeInterval(voucher.exp))
            guard expiresAt > Date() else {
                // Already dead on arrival — clock skew, or a stalled response. Showing a
                // QR that cannot be redeemed is worse than saying so.
                state = .expired
                return
            }
            // Length only. The value itself is never logged: these logs are readable on a
            // seized device, and one line would undo the whole exercise.
            Log.info("VEIL voucher: minted, valid \(Int(expiresAt.timeIntervalSinceNow))s (len=\(voucher.configURI.count))", category: "VEIL")
            state = .ready(configURI: voucher.configURI, expiresAt: expiresAt)
        } catch {
            let mapped = Self.state(for: error)
            if case .unavailable = mapped { VeilVoucherAvailability.markUnavailable() }
            if case .failed = mapped {
                Log.error("VEIL voucher: mint failed: \(error)", category: "VEIL")
            }
            state = mapped
        }
    }

    /// Called by the countdown when the voucher's window closes.
    func markExpired() {
        if case .ready = state { state = .expired }
    }
}
