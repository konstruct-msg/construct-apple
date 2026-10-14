import XCTest
@testable import Construct_Messenger

/// A received file's name comes from its sender and must not choose where the file is written
/// (2026-10-14: `../` in the name wrote outside the temporary directory).
final class OpenedFilesTests: XCTestCase {

    func testANameIsReducedToABareFileName() {
        XCTAssertEqual(OpenedFiles.safeName("report.pdf"), "report.pdf")
        XCTAssertEqual(OpenedFiles.safeName("../../Library/Preferences/x.plist"), "x.plist")
        XCTAssertEqual(OpenedFiles.safeName("..\\..\\evil.txt"), "evil.txt")
        XCTAssertEqual(OpenedFiles.safeName(".."), "file")
        XCTAssertEqual(OpenedFiles.safeName(".hidden"), "hidden")
        XCTAssertEqual(OpenedFiles.safeName(""), "file")
        XCTAssertEqual(OpenedFiles.safeName(String(repeating: "a", count: 300)).count, 120)
    }

    func testAFileIsWrittenInsideItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try OpenedFiles.write(Data([1, 2, 3]), mediaId: "../../m", name: "../../escape.txt", in: root)
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(base + "/"), url.path)
        XCTAssertEqual(url.lastPathComponent, "escape.txt")
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
    }
}
