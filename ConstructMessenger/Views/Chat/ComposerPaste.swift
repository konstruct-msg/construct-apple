//
//  ComposerPaste.swift
//  Construct Messenger
//
//  What ⌘V in the macOS composer pastes, decided from the pasteboard's type list alone. The text
//  field takes text and nothing else — an image on the clipboard was silently ignored until
//  2026-10-14 — so the composer answers ⌘V itself when the clipboard holds something to attach,
//  and leaves every other paste to the field.
//
//  A pure function of the types so it is testable without a pasteboard; the macOS caller reads
//  the objects once it knows which.
//

import Foundation
import UniformTypeIdentifiers

enum ComposerPaste: Equatable {
    /// Files copied in Finder: attached as files (images among them as images, as a drop does).
    case files
    /// A picture with no text beside it — a screenshot, "Copy Image" in a browser.
    case image
    /// Anything else, left to the text field.
    case text

    static func kind(types: [String]) -> ComposerPaste {
        let conforming = types.compactMap { UTType($0) }
        if conforming.contains(where: { $0.conforms(to: .fileURL) }) { return .files }
        // Rich text travels with a rendered picture of itself (Word, Pages, a web page
        // selection): with RTF beside it the picture is of the text, and the text is what was
        // meant. A bitmap is checked rather than any image, because PDF rides along the same way.
        let hasBitmap = conforming.contains { $0.conforms(to: .png) || $0.conforms(to: .tiff)
            || $0.conforms(to: .jpeg) || $0.conforms(to: .heic) }
        let hasRichText = conforming.contains { $0.conforms(to: .rtf) || $0.conforms(to: .rtfd) }
        return hasBitmap && !hasRichText ? .image : .text
    }
}
