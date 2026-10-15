import XCTest
@testable import Construct_Messenger

/// A document picked from Files or iCloud Drive is security-scoped, and reading it without asking
/// answers "you don't have permission" (Cocoa 257). On 2026-10-15 a PDF from iCloud Drive could
/// not be sent: its size was read so at the pick, and once that was fixed, again at the send. A
/// scoped URL cannot be made in a test, so this holds the rule the fix stands on — the send path
/// reads a file's size through `MessageValidator.size(of:)` only — and that the size it reads
/// still counts.
final class PickedFileAccessTests: XCTestCase {

    /// The files a picked document passes through before `MediaManager.uploadFile`, which asks for
    /// access itself.
    private let sendPath = [
        "ConstructMessenger/Utilities/MessageValidator.swift",
        "ConstructMessenger/Services/Messaging/ChatSendCoordinator.swift",
        "ConstructMessenger/Services/Messaging/MediaUploadManager.swift",
    ]

    /// Mutation: read `attributesOfItem` again in `validateMessage` — this reddens.
    func testTheSendPathReadsAFilesSizeInOnePlace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var reads: [String] = []
        for path in sendPath {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated()
            where ["attributesOfItem(", "fileSizeKey", "Data(contentsOf"].contains(where: line.contains) {
                reads.append("\(path):\(n + 1)")
            }
        }
        XCTAssertEqual(reads.count, 1, "a file's size is read outside size(of:): \(reads)")
        XCTAssertTrue(reads.first?.hasPrefix("ConstructMessenger/Utilities/MessageValidator.swift") == true)
    }

    /// The size the checks go by. Mutation: lose the size in `validateFile` — this reddens.
    func testTheCheckStillKnowsTheSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        try Data(count: 1234).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(try MessageValidator.size(of: url), 1234)
        XCTAssertEqual(try MessageValidator.validateFile(at: url), 1234)
        XCTAssertNoThrow(try MessageValidator.validateMessage(text: "", fileURLs: [url]))
    }
}
