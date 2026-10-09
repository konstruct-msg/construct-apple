//
//  UserText.swift
//  Construct Messenger
//
//  What a person reads when something fails, and only ever our own words (TODO 128).
//

import Foundation

/// A sentence for the screen, made from one of our localization keys and never from a `String`.
///
/// There is no initializer from text on purpose. The toast used to show whatever an error carried
/// — `localizedDescription`, an `RPCError.message` — and so people read "The operation couldn't be
/// completed. (GRPCCore.RuntimeError error 1.)" in Russian, a sentence no `.strings` file of ours
/// contains. With only a key to build from, a library's or the server's wording cannot reach the
/// screen by accident.
///
/// `arguments` fill the key's `%@` placeholders: sizes, a file name — what the person gave us,
/// never what an error said.
struct UserText: Equatable, Sendable {
    let key: String
    let arguments: [String]

    init(_ key: String, _ arguments: String...) {
        self.key = key
        self.arguments = arguments
    }

    var resolved: String {
        let format = NSLocalizedString(key, comment: "")
        return arguments.isEmpty ? format : String(format: format, arguments: arguments)
    }
}

/// An error whose text is ours: it says what happened in a key of our own. `AppError.from` shows
/// such an error's `userText`; any other error is classified by type and code, never by its words.
protocol UserFacingError: Error {
    var userText: UserText { get }
}
