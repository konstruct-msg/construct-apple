//
//  ComposerPasteTests.swift
//  ConstructMessengerTests
//
//  What ⌘V in the macOS composer attaches, by the clipboard's type list. The rule is pure so it
//  runs here; the Desktop composer reads the objects once it knows which.
//

import XCTest
import UniformTypeIdentifiers
@testable import Construct_Messenger

final class ComposerPasteTests: XCTestCase {

    private func kind(_ types: [UTType]) -> ComposerPaste {
        ComposerPaste.kind(types: types.map(\.identifier))
    }

    /// Copied in Finder: the file URL comes with the file name as text, and the file is meant.
    func testFilesCopiedInFinderAreAttached() {
        XCTAssertEqual(kind([.fileURL, .utf8PlainText]), .files)
    }

    /// A screenshot to the clipboard, or "Copy Image" in a browser (with the image's address).
    func testAPictureIsAttached() {
        XCTAssertEqual(kind([.png]), .image)
        XCTAssertEqual(kind([.tiff, .url]), .image)
        XCTAssertEqual(kind([.png, .html]), .image)
    }

    /// Word, Pages, a web page selection: the text travels with a picture of itself.
    func testRichTextWithAPictureOfItselfStaysText() {
        XCTAssertEqual(kind([.utf8PlainText, .rtf, .png]), .text)
        XCTAssertEqual(kind([.utf8PlainText, .rtfd, .tiff]), .text)
    }

    func testPlainTextAndPDFStayText() {
        XCTAssertEqual(kind([.utf8PlainText]), .text)
        XCTAssertEqual(kind([.utf8PlainText, .pdf]), .text)
        XCTAssertEqual(kind([]), .text)
    }
}
