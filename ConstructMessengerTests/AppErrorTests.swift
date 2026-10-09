//
//  AppErrorTests.swift
//  ConstructMessengerTests
//
//  What a person reads when something fails is ours (TODO 128): every case says a key that exists
//  in every locale, and no error's own words — a library's, the server's, the system's — reach the
//  screen. Each test names the mutation that must redden it.
//

import XCTest
import GRPCCore
@testable import Construct_Messenger

@MainActor
final class AppErrorTests: XCTestCase {

    private let locales = ["en", "ru", "ja", "fr", "hy-AM"]
    private let secret = "SECRET-WORDING-FROM-AN-ERROR"

    /// One of each case and of each error type that speaks for itself.
    private var everyCase: [AppError] {
        let network: [NetworkError] = [
            .connectionFailed, .disconnected, .notConnected, .invalidMessage, .encodingFailed,
            .decodingFailed, .serverError(message: secret, responseBody: nil),
        ]
        let validation: [MessageValidationError] = [
            .textTooLarge(currentSize: 2, maxSize: 1),
            .fileTooLarge(fileName: "a.bin", currentSize: 2, maxSize: 1),
            .unsupportedFileType(fileName: "a.xyz", extension: "xyz"),
            .totalSizeTooLarge(currentSize: 2, maxSize: 1),
            .emptyMessage, .selfSend,
        ]
        let ours: [UserFacingError] = [
            ContactLinkError.invalidURL, ContactLinkError.invalidPrefix, ContactLinkError.inviteExpired,
            ContactLinkError.inviteInvalid(secret), ContactLinkError.inviteAlreadyUsed,
            ContactLinkError.verificationFailed(NSError(domain: secret, code: 1)),
            ContactLinkError.recoveryKeyRequired,
            BackupError.invalidMnemonic, BackupError.fileNotFound(secret), BackupError.invalidFile,
            BackupError.decryptionFailed, BackupError.userIdMismatch,
            BackupEncryptionError.invalidPassword, BackupEncryptionError.encryptionFailed,
            BackupEncryptionError.decryptionFailed, BackupEncryptionError.invalidBackupFormat,
            BackupEncryptionError.keyDerivationFailed, BackupEncryptionError.dataCorrupted,
            DeviceLinkError.keyGenerationFailed, DeviceLinkError.invalidQRCode,
            DeviceLinkError.rejected, DeviceLinkError.expired,
            NearbyTransferError.authenticationFailed, NearbyTransferError.connectionClosed,
            VeilConfigImporter.ImportError.malformed, VeilConfigImporter.ImportError.badSignature,
            VeilConfigImporter.ImportError.expired, VeilConfigImporter.ImportError.unknownRelay,
        ]
        return network.map(AppError.network) + validation.map(AppError.validation)
            + ours.map { AppError.from($0) }
            + [
                .streamDisconnected, .serverRefused, .rateLimited, .sessionInitFailed(contactId: "c"),
                .decryptionFailed, .cryptoCoreUnavailable, .keyOperationFailed, .mediaUploadFailed,
                .mediaDownloadFailed, .mediaOptimizationFailed, .noSpace, .sessionExpired,
                .said(UserText("reaction_failed")), .unknown(detail: secret),
            ]
    }

    /// Every sentence is a key that resolves in every locale. Mutation: give any case a key that
    /// is in no `.strings` file — it is shown to the person verbatim, as the key.
    func testEveryCaseSaysAKeyEveryLocaleHas() throws {
        let app = Bundle(for: AuthViewModel.self)
        for locale in locales {
            let path = try XCTUnwrap(app.path(forResource: locale, ofType: "lproj"), locale)
            let bundle = try XCTUnwrap(Bundle(path: path), locale)
            for error in everyCase {
                let key = error.userText.key
                let value = bundle.localizedString(forKey: key, value: "\u{0}missing", table: nil)
                XCTAssertFalse(value.hasPrefix("\u{0}"), "\(key) has no \(locale) entry (\(error.logDescription))")
            }
            for action in ["retry", "error_action_reconnect", "error_action_sign_in", "username_taken"] {
                let value = bundle.localizedString(forKey: action, value: "\u{0}missing", table: nil)
                XCTAssertFalse(value.hasPrefix("\u{0}"), "\(action) has no \(locale) entry")
            }
        }
    }

    /// No error's words reach the screen: not the system's description, not the server's message,
    /// not a detail an error carries. Mutation: let `unknown` show its detail, or let `from` pass
    /// `localizedDescription` on — this reddens.
    func testNoErrorsOwnWordsAreShown() {
        let foreign: [Error] = [
            NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: secret]),
            RPCError(code: .internalError, message: secret),
            RPCError(code: .invalidArgument, message: secret),
            RPCError(code: .alreadyExists, message: secret),
            RuntimeError(code: .transportError, message: secret),
        ]
        for error in foreign {
            let shown = AppError.from(error).errorDescription ?? ""
            XCTAssertFalse(shown.contains(secret), "\(error) shown as «\(shown)»")
            XCTAssertFalse(error.userFacingMessage.contains(secret))
            XCTAssertFalse(error.usernameFacingMessage.contains(secret))
        }
        for error in everyCase {
            XCTAssertFalse((error.errorDescription ?? "").contains(secret), error.logDescription)
        }
        XCTAssertTrue(AppError.unknown(detail: secret).logDescription.contains(secret), "the log keeps it")
    }

    /// Classified by type and code. Mutation: drop any one branch of `from` — its error falls to
    /// `unknown` and reads "something went wrong".
    func testFailuresAreClassifiedByTypeAndCode() {
        func text(_ error: Error) -> String { AppError.from(error).userText.key }
        // The toast on the owner's screenshot: the gRPC client's own failure is no connection.
        XCTAssertEqual(text(RuntimeError(code: .clientIsStopped, message: "")), "error_no_connection")
        XCTAssertEqual(text(RPCError(code: .unavailable, message: "")), "error_no_connection")
        XCTAssertEqual(text(RPCError(code: .deadlineExceeded, message: "")), "error_no_connection")
        XCTAssertEqual(text(URLError(.notConnectedToInternet)), "error_no_connection")
        XCTAssertEqual(text(RPCError(code: .unauthenticated, message: "")), "error_sign_in_again")
        XCTAssertEqual(text(RPCError(code: .resourceExhausted, message: "")), "error_rate_limited")
        XCTAssertEqual(text(RPCError(code: .internalError, message: "")), "error_server")
        XCTAssertEqual(text(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), "error_no_space")
        XCTAssertEqual(text(CocoaError(.fileWriteOutOfSpace)), "error_no_space")
        XCTAssertEqual(text(ContactLinkError.inviteExpired), "invite_error_expired")
        XCTAssertEqual(text(NSError(domain: "anything", code: 7)), "error_generic")
    }

    /// The name is taken only where a name was set. Mutation: map ALREADY_EXISTS to the name in
    /// `from` — a second registration of a device would say the username is taken.
    func testAlreadyExistsMeansTheNameOnlyWhereANameWasSet() {
        let error = RPCError(code: .alreadyExists, message: "username is already taken")
        XCTAssertEqual(error.usernameFacingMessage, UserText("username_taken").resolved)
        XCTAssertNotEqual(error.userFacingMessage, UserText("username_taken").resolved)
    }

    /// A refused send is not a toast as well as a mark: the decision lives in the cases that stay
    /// silent. Mutation: make `sessionInitFailed` displayable.
    func testFailuresTheMessageAlreadyShowsAreNotToasted() {
        XCTAssertFalse(AppError.sessionInitFailed(contactId: "c").shouldDisplay)
        XCTAssertFalse(AppError.decryptionFailed.shouldDisplay)
        XCTAssertTrue(AppError.network(.connectionFailed).shouldDisplay)
    }
}
