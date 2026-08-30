//
//  CoreCapabilityPlatformParityTests.swift
//  ConstructMessengerTests
//
//  A call into the Rust core must not sit behind an iOS-only guard with nothing on the other side.
//
//  ## The defect this exists for
//
//  `request.supportsPqRatchet = supportsPqRatchet()` shipped inside `#if os(iOS)` on 2026-07-02.
//  It was correct then: macOS reached the core through `EngineAdapter`, and this function was not
//  callable there. That indirection was retired on 2026-07-28 — three crates, two xcframeworks,
//  both platforms direct UniFFI — and the guard stayed.
//
//  For a month every macOS device left the field at proto3's default and told the server it cannot
//  do suite 3. Nothing reported it, and nothing could: the capability is *consumed* from the peer's
//  bundle, which is platform-independent, so the desktop negotiated suite 3 as initiator and was
//  negotiated down as responder. Asymmetric, silent, and in the one place it matters most — the
//  desktop exists to be a second real device in one account, and a device whose crypto quietly
//  differs is a test instrument that lies.
//
//  ## Why a source scan
//
//  The premise of such a guard — "the core is not reachable here" — is not visible at the call
//  site and is not checked by anything. It expires when the build changes, and the code that
//  depended on it keeps compiling. So this asks the syntactic question that has a syntactic
//  answer: is a core entry point called on one platform and simply not called on the other.
//
//  `DesktopCoreReachabilityTests` in the Construct DesktopTests target asserts the other half —
//  that the core really is callable from macOS — so this scan is not resting on the same belief
//  the guard did.
//

import XCTest
@testable import Construct_Messenger

final class CoreCapabilityPlatformParityTests: XCTestCase {

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ConstructMessenger")
    }

    /// Call sites deliberately iOS-only despite the core being reachable on both platforms.
    /// Empty, and a new entry needs a reason that survives someone asking "what about the desktop".
    private static let allowed: Set<String> = []

    /// Every `public func` the UniFFI binding exposes.
    private func coreFunctionNames() throws -> Set<String> {
        let binding = sourceRoot.appendingPathComponent("construct_core.swift")
        let text = try String(contentsOf: binding, encoding: .utf8)
        var names: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("public func ") else { continue }
            let rest = t.dropFirst("public func ".count)
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { names.insert(String(name)) }
        }
        return names
    }

    private struct Violation: CustomStringConvertible {
        let file: String
        let line: Int
        let functions: [String]
        var description: String {
            "\(file):\(line) calls \(functions.joined(separator: ", ")) on iOS only"
        }
    }

    /// An iOS-only region with **no `#else`**: the call happens on one platform and not the other.
    /// A guard that provides an alternative has considered macOS, and is not what this looks for.
    private func violations(in text: String, file: String, core: Set<String>) -> [Violation] {
        var found: [Violation] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var openLine: Int? = nil
        var depth = 0
        var body: [String] = []
        var sawElse = false

        for (index, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)

            if openLine == nil {
                if t.hasPrefix("#if os(iOS)") || t.hasPrefix("#if canImport(UIKit)") {
                    openLine = index + 1; depth = 1; body = []; sawElse = false
                }
                continue
            }

            if t.hasPrefix("#if") { depth += 1; body.append(raw); continue }
            if t.hasPrefix("#endif") {
                depth -= 1
                if depth > 0 { body.append(raw); continue }
                if !sawElse {
                    let joined = body.joined(separator: "\n")
                    let called = core.filter { joined.range(of: "\($0)(") != nil }.sorted()
                    if !called.isEmpty {
                        found.append(Violation(file: file, line: openLine!, functions: called))
                    }
                }
                openLine = nil
                continue
            }
            if depth == 1, t.hasPrefix("#else") || t.hasPrefix("#elseif") { sawElse = true }
            body.append(raw)
        }
        return found
    }

    func testNoCoreCallIsIOSOnly() throws {
        let core = try coreFunctionNames()
        XCTAssertGreaterThan(core.count, 100,
                             "the binding scan found almost nothing — construct_core.swift moved or changed shape")

        var all: [Violation] = []
        let walker = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let name = url.lastPathComponent
            guard name != "construct_core.swift" else { continue }
            guard !url.path.contains("/Generated/") else { continue }
            guard !Self.allowed.contains(name) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            all.append(contentsOf: violations(in: text, file: name, core: core))
        }

        XCTAssertTrue(
            all.isEmpty,
            """
            A core call is made on iOS and simply not made on macOS:
            \(all.map(\.description).joined(separator: "\n"))
            The core is reachable on both platforms since 2026-07-28 (EngineAdapter retired). \
            If the difference is real, give the guard an `#else`; if it is not, delete the guard.
            """
        )
    }
}
