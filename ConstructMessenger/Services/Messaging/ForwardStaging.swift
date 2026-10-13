//
//  ForwardStaging.swift
//  Construct Messenger
//
//  Where a forward puts the bytes it re-sends, and the rule that follows from the place: a file
//  or voice message read from here is uploaded as a new object (`MediaUploadReuse.forSend`).
//
//  Files and voice messages travel through the send path as URLs — queued while a session opens,
//  kept for a retry after a failed upload, replayed — and a flag beside the URL would have to
//  survive every one of those hops; missing one would quietly reuse the original's object. The
//  URL survives all of them, so it carries the rule. Photos and videos carry it on the attachment
//  (`MediaAttachment.isForwarded`), which travels whole.
//
//  The copies are plaintext in the app's temporary directory, as the file a person opens from a
//  chat already is; each is removed once its upload has succeeded.
//

import Foundation

enum ForwardStaging {

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("forward", isDirectory: true)
    }

    /// A new place for one file, keeping its name: the name is what the recipient sees.
    static func newFileURL(named filename: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = (filename as NSString).lastPathComponent
        return folder.appendingPathComponent(name.isEmpty ? "file" : name)
    }

    static func contains(_ url: URL) -> Bool {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/")
    }

    /// What an upload of `url` to `peerId` may reuse: a staged copy is a forward's, and reuses nothing.
    static func reuse(for url: URL, to peerId: String) -> MediaUploadReuse {
        .forSend(to: peerId, forwarded: contains(url))
    }

    /// Remove a staged copy and its folder. Anything outside the staging directory is left alone.
    static func discard(_ url: URL) {
        guard contains(url) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
