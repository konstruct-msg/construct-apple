//
//  LogRedaction.swift
//  Construct Messenger
//
//  A VEIL front's name never reaches a log in the clear (TODO 135,
//  construct-docs decisions/veil-front-in-logs-is-a-keyed-label.md). Every line `Log` writes —
//  to os_log and to the diagnostics file — passes through here: a registered front name (host,
//  SNI, Host header) becomes `front#xxxxxxxx`, any IPv4 address but loopback `ip#xxxxxxxx`.
//  The label is the first four bytes of HMAC-SHA256 under a random key of this device, so one
//  front is one label in this device's logs and cannot be matched across devices — a bare hash
//  would not do: there are few fronts, and a censor hashes the candidates.
//
//  Names arrive from where fronts arrive (`VeilRelay`, the candidate lists), not from each log
//  call: the address also travels inside state descriptions and error text, which no call site
//  sees.
//

import CryptoKit
import Foundation

enum LogRedaction {

    /// Names in the clear only where the person reading the log is the one who built the app: a
    /// build installed from Xcode, the simulator, a Mac app run from DerivedData. Not `DEBUG`:
    /// TestFlight builds are the Beta configuration, which compiles with it.
    static let showsNames: Bool = {
        #if targetEnvironment(simulator)
        return true
        #elseif os(iOS)
        // Xcode installs carry it; TestFlight and the App Store strip it (as `ProbeBanner`).
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #else
        return Bundle.main.bundlePath.contains("/DerivedData/")
        #endif
    }()

    static let keyAccount = "construct.logLabel.key.v1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var names = Set<String>()
    nonisolated(unsafe) private static var key: SymmetricKey?
    nonisolated(unsafe) private static var resolvingKey = false
    /// After the Keychain did not answer (or held a key of the wrong size): not asked again
    /// before this, so a locked phone does not cost a Keychain call per log line.
    nonisolated(unsafe) private static var retryAt = Date.distantPast
    private static let keyRetryInterval: TimeInterval = 60
    /// For a line logged while the device key is being read — the Keychain logs too — and for a
    /// process whose Keychain does not answer.
    private static let processKey = SymmetricKey(size: .bits256)

    /// Front names to hide from now on: hosts (a `host:port` is taken by its host), SNIs, Host
    /// headers. Empty and loopback names are ignored.
    static func register<S: Sequence>(_ candidates: S) where S.Element == String {
        guard !showsNames else { return }
        let hosts = candidates.compactMap(host(of:))
        guard !hosts.isEmpty else { return }
        lock.withLock { names.formUnion(hosts) }
    }

    /// Every front this install already knows, at launch — so a line logged before one of them is
    /// dialled, or by a path that never makes a `VeilRelay` of it, is covered too. The bundled
    /// seeds, the signed manifest's (with their SNIs and Host headers), the learned ones.
    static func registerKnownFronts() {
        guard !showsNames else { return }
        var names = VEILConfig.hardcodedRelayAddresses
        names += VEILConfig.hardcodedRelaySNIs.values
        names += VEILConfig.hardcodedRelayAlternativeSNIs.values.flatMap { $0 }
        names += VeilProxyStore.cachedRelayList()
        for relay in VeilCertFetcher.cachedRelayInfosSync() ?? [] {
            names += [relay.addressWithPort, relay.domain, relay.sni, relay.wtHostHeader].compactMap { $0 }
            names += relay.alternativeSNIs ?? []
        }
        for front in VeilLearnedFrontStore.shared.all() {
            names += [front.address, front.sni]
        }
        register(names)
    }

    static func register(_ relay: VeilRelay) {
        register([relay.address, relay.tlsServerName, relay.wtHostHeader].compactMap { $0 } + relay.alternativeSNIs)
    }

    /// `line` as the log may keep it.
    static func redact(_ line: String) -> String {
        guard !showsNames else { return line }
        let known = lock.withLock { names }
        return redact(line, names: known, key: deviceKey())
    }

    // MARK: - The rule, pure

    /// A bracketed IPv6 address, as it appears in `[…]:port`; loopback `[::1]` excepted.
    private static let ipv6 = try! NSRegularExpression(pattern: #"\[(?!::1\])[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*\]"#)

    /// A `veil-config` link carries a front's coordinates in its query (base64url JSON): the
    /// query goes whole, whether or not its front was registered before the line was logged.
    private static let veilConfigQuery = try! NSRegularExpression(pattern: #"(veil-config\?)[^\s"'<>)]*"#)

    private static let ipv4 = try! NSRegularExpression(
        pattern: #"(?<![\d.])(?!127\.)(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#
    )

    static func redact(_ line: String, names: Set<String>, key: SymmetricKey) -> String {
        var out = veilConfigQuery.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "$1…"
        )
        // Longest first, so a name that contains another is replaced whole.
        for name in names.sorted(by: { $0.count > $1.count }) where out.range(of: name, options: .caseInsensitive) != nil {
            out = out.replacingOccurrences(of: name, with: "front#\(label(name, key: key))", options: .caseInsensitive)
        }
        for pattern in [ipv6, ipv4] {
            let matches = pattern.matches(in: out, range: NSRange(out.startIndex..., in: out))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                let address = out[range].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                out.replaceSubrange(range, with: "ip#\(label(address, key: key))")
            }
        }
        return out
    }

    static func label(_ name: String, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(name.lowercased().utf8), using: key)
        return Data(mac).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func host(of candidate: String) -> String? {
        var host = candidate.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
            return host.isEmpty || host == "::1" ? nil : host.lowercased()
        }
        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber),
           host.firstIndex(of: ":") == colon {
            host = String(host[..<colon])
        }
        guard !host.isEmpty, host != "localhost", !host.hasPrefix("127.") else { return nil }
        return host.lowercased()
    }

    // MARK: - Key

    /// The device's key, from the Keychain (this device only, so never in a backup), made on first
    /// use. Read outside the lock: the Keychain logs, and that line comes back here. When the
    /// Keychain does not answer — before the first unlock — the process key: the names are still
    /// hidden, the labels just differ from other launches.
    private static func deviceKey() -> SymmetricKey {
        let resolve: Bool = lock.withLock {
            if key != nil || resolvingKey || Date() < retryAt { return false }
            resolvingKey = true
            return true
        }
        guard resolve else { return lock.withLock { key } ?? processKey }
        var found: SymmetricKey?
        switch KeychainManager.shared.read(forKey: keyAccount) {
        case .found(let data) where data.count == 32:
            found = SymmetricKey(data: data)
        case .absent:
            let fresh = SymmetricKey(size: .bits256)
            if KeychainManager.shared.saveData(
                fresh.withUnsafeBytes { Data($0) }, forKey: keyAccount,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ) {
                found = fresh
            }
        default:
            break
        }
        lock.withLock {
            key = found
            resolvingKey = false
            if found == nil { retryAt = Date().addingTimeInterval(keyRetryInterval) }
        }
        return found ?? processKey
    }
}
