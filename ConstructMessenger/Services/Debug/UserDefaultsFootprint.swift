//
//  UserDefaultsFootprint.swift
//  Construct Messenger
//
//  What is actually taking up room in NSUserDefaults, grouped so a leak is visible.
//
//  Device, 2026-08-11 15:21:25:
//
//      CFPrefsPlistSource … Attempting to store >= 4194304 bytes of data in
//      CFPreferences/NSUserDefaults on this platform is invalid. This is a bug in
//      Construct Messenger or a library it uses.
//
//  Past 4 MB, CFPreferences starts dropping writes and slows launch, and the message names the
//  domain rather than the offending key. Sixty-four files in this app write to UserDefaults, so
//  the question "which one" is not answerable by reading them.
//
//  WHY GROUPING, and not simply the largest keys: the leak that prompted this writes one key per
//  outgoing message (`construct.outgoingWirePayload.<uuid>`). Three thousand keys of a kilobyte
//  each is 3 MB that a top-N-by-key report shows as nothing at all — every individual entry is
//  unremarkable. The report has to collapse id-bearing keys into their family before it can see
//  the shape, or it reproduces the exact blindness that let this accumulate.
//
//  DEBUG only.
//

import Foundation

enum UserDefaultsFootprint {

    /// The point at which CFPreferences declares the domain invalid.
    static let domainLimit = 4 * 1024 * 1024

    struct Group: Equatable {
        let name: String
        let bytes: Int
        let keys: Int
    }

    /// Collapses the variable part of a key so one-key-per-id families add up.
    ///
    /// A run of 8+ characters drawn from hex digits and hyphens, containing at least one digit or
    /// hyphen, is treated as an identifier and replaced with `*`. The digit/hyphen requirement is
    /// what keeps ordinary words out of it — without it, any 8-letter run of `a`–`f` would be
    /// mistaken for an id and two unrelated settings would be merged into one meaningless row.
    static func family(of key: String) -> String {
        var result = ""
        var run = ""
        var runHasDigitOrDash = false

        func flush() {
            if run.count >= 8 && runHasDigitOrDash {
                result += "*"
            } else {
                result += run
            }
            run = ""
            runHasDigitOrDash = false
        }

        for character in key {
            let isHex = character.isHexDigit
            let isDash = character == "-"
            if isHex || isDash {
                run.append(character)
                if character.isNumber || isDash { runHasDigitOrDash = true }
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }

    /// Families ordered by total bytes, largest first. Ties break on name so the output is stable
    /// between runs and two logs can be diffed.
    static func ranked(sizes: [String: Int], limit: Int) -> [Group] {
        var totals: [String: (bytes: Int, keys: Int)] = [:]
        for (key, bytes) in sizes {
            let name = family(of: key)
            let current = totals[name] ?? (0, 0)
            totals[name] = (current.bytes + bytes, current.keys + 1)
        }
        return totals
            .map { Group(name: $0.key, bytes: $0.value.bytes, keys: $0.value.keys) }
            .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
            .prefix(limit)
            .map { $0 }
    }

    #if DEBUG
    /// Measures the app's own domain and logs the largest families.
    ///
    /// Deliberately reads the persistent domain rather than `dictionaryRepresentation()`: the
    /// latter includes inherited global/system defaults, which are not ours and would pad the
    /// total with bytes nobody here can do anything about.
    static func logSummary(limit: Int = 6) {
        guard let bundleId = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleId) else {
            Log.info("USERDEFAULTS: no persistent domain to measure", category: "Diagnostics")
            return
        }

        var sizes: [String: Int] = [:]
        for (key, value) in domain {
            let bytes = (try? PropertyListSerialization.data(
                fromPropertyList: value, format: .binary, options: 0
            ).count) ?? 0
            sizes[key] = bytes
        }

        let total = sizes.values.reduce(0, +)
        let pressure = total >= domainLimit ? " OVER-LIMIT" : ""
        Log.info(
            "USERDEFAULTS: total=\(total / 1024)KB keys=\(sizes.count) limit=\(domainLimit / 1024)KB\(pressure)",
            category: "Diagnostics"
        )
        for group in ranked(sizes: sizes, limit: limit) {
            Log.info(
                "USERDEFAULTS:   \(group.bytes / 1024)KB  \(group.name)  (\(group.keys) key(s))",
                category: "Diagnostics"
            )
        }
    }
    #endif
}
