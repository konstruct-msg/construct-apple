//
//  AppError.swift
//  Construct Messenger
//
//  Unified application error type.
//  All domain errors (NetworkError, CryptoManagerError, etc.) map to AppError
//  before being displayed to the user or reported to ErrorRouter.
//

import Foundation
import GRPCCore

// MARK: - AppError

/// What failed, as the app tells a person about it (TODO 128).
///
/// The text shown is always `userText` — a key of ours, per case. No case carries a sentence from
/// the error it was made from: `unknown` keeps its detail for the log, and our own sentences come
/// in through `said`, which takes a `UserText` and so only a key.
enum AppError: LocalizedError {

    // MARK: - Network
    /// Server is unreachable or connection was lost
    case network(NetworkError)
    /// gRPC stream failed to reconnect
    case streamDisconnected
    /// The server answered, with an error that is not ours to explain
    case serverRefused
    /// The server is limiting how often this can be done
    case rateLimited

    // MARK: - Session / Crypto
    /// E2EE session could not be established with a contact
    case sessionInitFailed(contactId: String)
    /// Message could not be decrypted (session out of sync)
    case decryptionFailed
    /// Cryptographic core is not initialised
    case cryptoCoreUnavailable
    /// Key generation or rotation failed
    case keyOperationFailed

    // MARK: - Media
    /// File/image upload failed
    case mediaUploadFailed
    /// File/image download failed
    case mediaDownloadFailed
    /// Media optimisation (resize/compress) failed
    case mediaOptimizationFailed
    /// The device is out of storage
    case noSpace

    // MARK: - Validation
    /// Message content failed validation (too large, empty, bad type)
    case validation(MessageValidationError)

    // MARK: - Authentication
    /// Session token expired and could not be refreshed
    case sessionExpired

    // MARK: - Generic
    /// Our own sentence for a failure no other case names.
    case said(UserText)
    /// Anything unclassified. The detail goes to the log; the screen says "something went wrong".
    case unknown(detail: String)

    /// Non-error informational banner (invite safety, etc.). Optional action title for the toast button.
    case notice(message: String, actionTitle: String?)
}

// MARK: - Severity

extension AppError {
    enum Severity {
        /// Informational — shown briefly, no action needed
        case info
        /// Something went wrong but the app can recover automatically
        case warning
        /// Requires user attention or action
        case critical
    }

    var severity: Severity {
        switch self {
        case .validation:              return .info
        case .mediaOptimizationFailed: return .info
        case .notice:                  return .info
        case .decryptionFailed:        return .warning
        case .streamDisconnected:      return .warning
        case .network:                 return .warning
        case .rateLimited:             return .warning
        case .mediaUploadFailed,
             .mediaDownloadFailed:     return .warning
        case .said:                    return .warning
        case .sessionInitFailed,
             .cryptoCoreUnavailable,
             .keyOperationFailed,
             .serverRefused,
             .noSpace,
             .sessionExpired,
             .unknown:                 return .critical
        }
    }
}

// MARK: - Recovery

extension AppError {
    enum Recovery {
        case none
        case retry
        case reconnect
        case relogin
    }

    var recovery: Recovery {
        switch self {
        case .network, .streamDisconnected: return .reconnect
        case .mediaUploadFailed:            return .retry
        case .sessionInitFailed:            return .retry
        case .sessionExpired:               return .relogin
        default:                            return .none
        }
    }

    /// User-visible label for the recovery button, nil if no action available.
    var recoveryActionTitle: String? {
        switch self {
        case .notice(_, let actionTitle):
            return actionTitle
        default:
            switch recovery {
            case .none:       return nil
            case .retry:      return UserText("retry").resolved
            case .reconnect:  return UserText("error_action_reconnect").resolved
            case .relogin:    return UserText("error_action_sign_in").resolved
            }
        }
    }
}

// MARK: - What the person reads

extension AppError {
    /// The sentence for this failure. Every case answers with a key of ours.
    var userText: UserText {
        switch self {
        case .network(let e):           return e.userText
        case .streamDisconnected:       return UserText("error_no_connection")
        case .serverRefused:            return UserText("error_server")
        case .rateLimited:              return UserText("error_rate_limited")
        case .sessionInitFailed:        return UserText("error_peer_unreachable")
        case .decryptionFailed:         return UserText("error_decryption")
        case .cryptoCoreUnavailable,
             .keyOperationFailed:       return UserText("error_encryption")
        case .mediaUploadFailed:        return UserText("error_upload_failed")
        case .mediaDownloadFailed:      return UserText("error_download_failed")
        case .mediaOptimizationFailed:  return UserText("error_media_processing")
        case .noSpace:                  return UserText("error_no_space")
        case .validation(let e):        return e.userText
        case .sessionExpired:           return UserText("error_sign_in_again")
        case .said(let text):           return text
        case .unknown:                  return UserText("error_generic")
        case .notice:                   return UserText("error_generic")
        }
    }

    var errorDescription: String? {
        if case .notice(let message, _) = self { return message }
        return userText.resolved
    }

    /// What the log gets: the case, and for `unknown` the detail the screen never shows.
    var logDescription: String {
        switch self {
        case .unknown(let detail): return "unknown: \(detail)"
        case .notice(let message, _): return "notice: \(message)"
        default: return String(describing: self)
        }
    }
}

// MARK: - Mapping from domain errors

extension AppError {
    /// Map any `Error` to what the person is told. By type and code only: an error's own words
    /// reach the log, never the screen.
    static func from(_ error: Error) -> AppError {
        switch error {
        case let e as AppError:
            return e
        case let e as NetworkError:
            return .network(e)
        case let e as MessageValidationError:
            return .validation(e)
        case let e as UserFacingError:
            return .said(e.userText)
        case let e as CryptoManagerError:
            switch e {
            case .coreNotInitialized:          return .cryptoCoreUnavailable
            case .sessionNotFound,
                 .sessionInitializationFailed: return .sessionInitFailed(contactId: "")
            case .decryptionFailed,
                 .invalidCiphertext:           return .decryptionFailed
            case .duplicateMessage:            return .decryptionFailed
            case .decryptionFailedNoArchive:   return .decryptionFailed
            case .encryptionFailed,
                 .invalidKeyData,
                 .invalidSignature,
                 .keyStatePersistFailed:       return .keyOperationFailed
            }
        case let e as RPCError:
            switch e.code {
            case .unauthenticated:             return .sessionExpired
            case .unavailable, .deadlineExceeded:
                                               return .network(.connectionFailed)
            case .resourceExhausted:           return .rateLimited
            default:                           return .serverRefused
            }
        // The gRPC client's own failures — not started, stopped, transport closed — never an
        // answer from the server. This was the "GRPCCore.RuntimeError, error 1" toast.
        case is RuntimeError, is GRPCClientError:
            return .network(.connectionFailed)
        case let e as URLError:
            return e.code == .notConnectedToInternet || e.code == .networkConnectionLost
                || e.code == .timedOut || e.code == .cannotConnectToHost || e.code == .cannotFindHost
                ? .network(.connectionFailed) : .unknown(detail: String(describing: e))
        default:
            let ns = error as NSError
            if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
                || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
                return .noSpace
            }
            return .unknown(detail: String(describing: error))
        }
    }

    /// Whether this error should be reported to the user or silently logged only.
    var shouldDisplay: Bool {
        switch self {
        case .decryptionFailed:
            return false   // session self-heals; no user noise
        case .sessionInitFailed:
            // Message bubble already shows retry — banner is redundant and misleading
            // (often caused by stale contact keys, not a fixable network issue).
            return false
        default:
            return true
        }
    }
}

extension NetworkError {
    var userText: UserText {
        switch self {
        case .connectionFailed, .disconnected, .notConnected:
            return UserText("error_no_connection")
        case .serverError:
            return UserText("error_server")
        case .invalidMessage, .encodingFailed, .decodingFailed:
            return UserText("error_generic")
        }
    }
}
