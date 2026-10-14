import CryptoKit
import Foundation

/// Where a received file is written so the system can open it (Quick Look, the player, Save as).
///
/// Its name comes from the sender. Until 2026-10-14 it was appended to the temporary directory as
/// it came, so a name with `../` in it wrote outside that directory, into the app's container.
/// The name is reduced to a bare file name here — the rule Android's `FileContent.safeName` has —
/// and each file gets its own folder, so two files with one name do not overwrite each other.
/// Copies older than an hour are removed on the next open, as Android does: the file is a
/// plaintext copy of something the store keeps sealed.
enum OpenedFiles {
    static let keep: TimeInterval = 60 * 60
    private static let maxNameLength = 120

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("open", isDirectory: true)
    }

    /// A name that cannot leave its folder: the last path component, without leading dots,
    /// at most 120 characters; "file" when nothing is left.
    static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var base = last.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        base = base.replacingOccurrences(of: "\0", with: "")
        let short = String(base.prefix(maxNameLength))
        return short.isEmpty ? "file" : short
    }

    static func write(_ data: Data, mediaId: String, name: String, in directory: URL = directory) throws -> URL {
        removeOld(in: directory)
        // The media id is the sender's too: a digest of it names the folder.
        let digest = SHA256.hash(data: Data(mediaId.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safeName(name))
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        return url
    }

    private static func removeOld(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-keep)
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: folder) }
        }
    }
}
