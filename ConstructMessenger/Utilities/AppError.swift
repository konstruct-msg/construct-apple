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

enum AppError: LocalizedError {

    // MARK: - Network
    /// Server is unreachable or connection was lost
    case network(NetworkError)
    /// gRPC stream failed to reconnect
    case streamDisconnected

    // MARK: - Session / Crypto
    /// E2EE session could not be established with a contact
    case sessionInitFailed(contactId: String)
    /// Message could not be decrypted (session out of sync)
    case decryptionFailed
    /// Cryptographic core is not initialised
    case cryptoCoreUnavailable
    /// Key generation or rotation failed
    case keyOperationFailed(String)

    // MARK: - Media
    /// File/image upload failed
    case mediaUploadFailed(String)
    /// File/image download failed
    case mediaDownloadFailed(String)
    /// Media optimisation (resize/compress) failed
    case mediaOptimizationFailed

    // MARK: - Validation
    /// Message content failed validation (too large, empty, bad type)
    case validation(MessageValidationError)

    // MARK: - Authentication
    /// Login / token refresh failed
    case authFailed(String)
    /// Session token expired and could not be refreshed
    case sessionExpired

    // MARK: - Generic
    /// Catch-all for unmapped errors; use sparingly
    case unknown(String)
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
        case .decryptionFailed:        return .warning
        case .streamDisconnected:      return .warning
        case .network:                 return .warning
        case .mediaUploadFailed,
             .mediaDownloadFailed:     return .warning
        case .sessionInitFailed,
             .cryptoCoreUnavailable,
             .keyOperationFailed,
             .sessionExpired,
             .authFailed,
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
        case .sessionExpired, .authFailed:  return .relogin
        default:                            return .none
        }
    }

    /// User-visible label for the recovery button, nil if no action available.
    var recoveryActionTitle: String? {
        switch recovery {
        case .none:       return nil
        case .retry:      return "Retry"
        case .reconnect:  return "Reconnect"
        case .relogin:    return "Log in again"
        }
    }
}

// MARK: - LocalizedError

extension AppError {
    var errorDescription: String? {
        switch self {
        case .network(let e):
            return e.errorDescription ?? "Connection error"
        case .streamDisconnected:
            return "Lost connection to server"
        case .sessionInitFailed:
            return "Could not establish secure connection"
        case .decryptionFailed:
            return "Could not decrypt message"
        case .cryptoCoreUnavailable:
            return "Encryption engine unavailable"
        case .keyOperationFailed(let detail):
            return "Key operation failed: \(detail)"
        case .mediaUploadFailed(let detail):
            return "Upload failed: \(detail)"
        case .mediaDownloadFailed(let detail):
            return "Download failed: \(detail)"
        case .mediaOptimizationFailed:
            return "Could not process media"
        case .validation(let e):
            return e.errorDescription
        case .authFailed(let detail):
            return detail.isEmpty ? "Authentication failed" : detail
        case .sessionExpired:
            return "Session expired, please log in again"
        case .unknown(let detail):
            return detail.isEmpty ? "An unexpected error occurred" : detail
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .decryptionFailed:
            return "The conversation will re-sync automatically"
        case .sessionExpired:
            return "Your session has expired"
        default:
            return nil
        }
    }
}

// MARK: - Mapping from domain errors

extension AppError {
    /// Map any domain `Error` to an `AppError`.
    static func from(_ error: Error) -> AppError {
        switch error {
        case let e as AppError:
            return e
        case let e as NetworkError:
            return .network(e)
        case let e as MessageValidationError:
            return .validation(e)
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
                 .invalidSignature:            return .keyOperationFailed(e.localizedDescription)
            case .pqxdhOtpkMissing:            return .sessionInitFailed(contactId: "")
            }
        case let e as RPCError:
            switch e.code {
            case .unauthenticated:             return .sessionExpired
            case .unavailable, .deadlineExceeded:
                                               return .network(.connectionFailed)
            default:
                let msg = e.message.isEmpty ? "Server error (code \(e.code.rawValue))" : e.message
                return .unknown(msg)
            }
        default:
            let msg = error.localizedDescription
            return .unknown(msg)
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
        case .unknown(let detail):
            // Suppress raw internal strings that must never reach the UI.
            let internalPrefixes = ["Orchestrator returned", "OutboundSessionService", "No session with contact"]
            return !internalPrefixes.contains { detail.hasPrefix($0) }
        default:
            return true
        }
    }
}
