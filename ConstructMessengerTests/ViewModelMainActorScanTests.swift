//
//  ViewModelMainActorScanTests.swift
//  ConstructMessengerTests
//
//  `@Observable` view models are `@MainActor` (AGENTS.md, Code). SwiftUI reads them on the main
//  actor; one that is not can be mutated from a `Task` off it, which Swift 6 reports only where
//  the mutation is written, never at the view model. On 2026-11-03 nine of ten in ViewModels/ were
//  isolated and `SecurityViewModel` — the PIN and lock state — was not.
//

import XCTest

/// Names of `@Observable` classes in `source` that are view models (in ViewModels/, or named
/// `…ViewModel`) and whose attribute run lacks `@MainActor`.
enum ViewModelMainActorScan {
    static func unisolated(in source: String, isViewModelsDir: Bool) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var out: [String] = []
        for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces).hasPrefix("@Observable") {
            var attributes: [String] = []
            var start = index
            while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("@") { start -= 1 }
            var end = index
            var declaration: String?
            while end < lines.count {
                let text = lines[end]
                attributes.append(text)
                if let match = text.range(of: #"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) {
                    declaration = String(text[match]).components(separatedBy: .whitespaces).last
                    break
                }
                if text.range(of: #"\b(struct|enum|actor|protocol)\s"#, options: .regularExpression) != nil { break }
                end += 1
            }
            guard let name = declaration else { continue }
            guard isViewModelsDir || name.hasSuffix("ViewModel") else { continue }
            let run = (lines[start..<index] + attributes).joined(separator: " ")
            if !run.contains("@MainActor") { out.append(name) }
        }
        return out
    }
}

final class ViewModelMainActorScanTests: XCTestCase {

    func testTheScanSeesAMissingIsolation() {
        XCTAssertEqual(ViewModelMainActorScan.unisolated(in: "@Observable\nfinal class FooViewModel {", isViewModelsDir: false), ["FooViewModel"])
        XCTAssertEqual(ViewModelMainActorScan.unisolated(in: "@Observable\nfinal class Foo {", isViewModelsDir: true), ["Foo"])
        XCTAssertEqual(ViewModelMainActorScan.unisolated(in: "@MainActor\n@Observable\nfinal class FooViewModel {", isViewModelsDir: false), [])
        XCTAssertEqual(ViewModelMainActorScan.unisolated(in: "@Observable @MainActor final class FooViewModel {", isViewModelsDir: false), [])
        XCTAssertEqual(ViewModelMainActorScan.unisolated(in: "@Observable\nfinal class Store {", isViewModelsDir: false), [],
                       "an @Observable that is not a view model is not this rule's")
    }

    func testEveryObservableViewModelIsMainActor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var viewModels = 0
        var found: [String] = []
        for dir in ["ConstructMessenger", "Construct Desktop"] {
            guard let walk = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else {
                return XCTFail("cannot walk \(dir)")
            }
            for case let url as URL in walk where url.pathExtension == "swift" && !url.path.contains("/Generated/") {
                let source = try String(contentsOf: url, encoding: .utf8)
                guard source.contains("@Observable") else { continue }
                let inDir = url.path.contains("/ConstructMessenger/ViewModels/")
                if inDir || source.contains("ViewModel {") { viewModels += 1 }
                found += ViewModelMainActorScan.unisolated(in: source, isViewModelsDir: inDir)
                    .map { "\(url.lastPathComponent): \($0)" }
            }
        }
        XCTAssertGreaterThanOrEqual(viewModels, 10, "the walk found too few view models to mean anything")
        XCTAssertEqual(found, [], "mark these @MainActor")
    }
}
