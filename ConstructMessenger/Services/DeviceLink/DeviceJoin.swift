//
//  DeviceJoin.swift
//  ConstructMessenger
//
//  The new device's wait in Flow B: the core says when to ask, when to sign in and how it ends
//  (construct-rules `device_join`); this makes the two calls.
//  `decisions/a-joining-device-signs-in-with-its-own-key.md`.
//

import Foundation

@MainActor
struct DeviceJoin {

    enum Outcome {
        case signedIn(AuthServiceClient.ConfirmLinkResult)
        case ended(DeviceJoinEnd)
    }

    /// `CheckJoinRequestStatusResponse.Status`, by its number.
    let status: () async throws -> Int32
    /// `AuthenticateDevice` under the key we asked to join with.
    let signIn: () async throws -> AuthServiceClient.ConfirmLinkResult
    var nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    var sleep: (_ ms: Int64) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }

    /// From the moment our code is on the screen. Throws only when cancelled.
    func run() async throws -> Outcome {
        let wait = DeviceJoinWait(nowMs: nowMs())
        while true {
            try Task.checkCancellation()
            switch wait.next(nowMs: nowMs()) {
            case .wait(let ms):
                try await sleep(ms)
            case .ask:
                do {
                    wait.onStatus(status: try await status(), nowMs: nowMs())
                } catch {
                    Log.debug("join request status: \(error)", category: "DeviceLink")
                    wait.onStatusFailed(nowMs: nowMs())
                }
            case .signIn:
                do {
                    return .signedIn(try await signIn())
                } catch {
                    Log.info("join sign-in: \(error)", category: "DeviceLink")
                    wait.onSignInFailed(failure: SendFailure.kind(of: error), nowMs: nowMs())
                }
            case .ended(let end):
                return .ended(end)
            }
        }
    }
}

extension DeviceLinkError {
    init(_ end: DeviceJoinEnd) {
        switch end {
        case .rejected:         self = .rejected
        case .expired:          self = .expired
        case .signInRefused:    self = .signInRefused
        case .letInUnreachable: self = .letInUnreachable
        }
    }
}
