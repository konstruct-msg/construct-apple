//
//  SealedFile.swift
//  Construct Messenger
//
//  Files at rest sealed under `LocalStoreKey`, in chunks, so a video is neither held whole in
//  memory nor streamed out in the clear. `decisions/macos-store-encrypted-at-rest.md` (variant B)
//

import CryptoKit
import Foundation

/// `CTS1` ‖ file nonce(8) ‖ chunk₀ ‖ chunk₁ ‖ … — each chunk is AES-256-GCM ciphertext ‖ tag(16)
/// of up to `chunkSize` bytes.
///
/// - Nonce of chunk *i*: file nonce ‖ *i* (big-endian `UInt32`). The file nonce is random per file,
///   so no two chunks anywhere share a nonce under the one key.
/// - Associated data: the file's context (for media, its id) ‖ *i* ‖ final flag. A chunk moved to
///   another file or position does not open, and a file cut after a full chunk fails at the end
///   instead of reading as a shorter file.
/// - The last chunk is always present and flagged, even for an empty file.
enum SealedFile {

    static let magic = Data("CTS1".utf8)
    static let headerSize = 4 + 8
    static let chunkSize = 64 * 1024
    static let tagSize = 16

    enum Failure: Error {
        case notSealed, truncated, corrupt
    }

    // MARK: - Whole values

    static func seal(_ plaintext: Data, under key: SymmetricKey, context: String) throws -> Data {
        let writer = try Writer(key: key, context: context)
        var out = writer.header
        var offset = plaintext.startIndex
        repeat {
            let end = plaintext.index(offset, offsetBy: chunkSize, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
            out.append(try writer.sealChunk(plaintext[offset..<end], final: end == plaintext.endIndex))
            offset = end
        } while offset < plaintext.endIndex
        return out
    }

    static func open(_ sealed: Data, under key: SymmetricKey, context: String) throws -> Data {
        let sealed = Data(sealed)   // zero-based indices below
        guard isSealed(sealed) else { throw Failure.notSealed }
        let fileNonce = sealed.subdata(in: 4..<headerSize)
        var out = Data()
        var offset = sealed.startIndex + headerSize
        var index: UInt32 = 0
        while true {
            let end = sealed.index(offset, offsetBy: chunkSize + tagSize, limitedBy: sealed.endIndex) ?? sealed.endIndex
            let final = end == sealed.endIndex
            out.append(try openChunk(sealed[offset..<end], index: index, final: final,
                                     fileNonce: fileNonce, key: key, context: context))
            if final { return out }
            offset = end
            index += 1
        }
    }

    static func isSealed(_ data: Data) -> Bool {
        data.count >= headerSize + tagSize && data.prefix(4) == magic
    }

    static func isSealed(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == magic
    }

    /// The clear size of a sealed file of `fileSize` bytes: every chunk but the last is full.
    static func plaintextSize(ofSealedFileSize fileSize: UInt64) -> UInt64? {
        guard fileSize >= UInt64(headerSize + tagSize) else { return nil }
        let body = fileSize - UInt64(headerSize)
        let full = UInt64(chunkSize + tagSize)
        let chunks = (body + full - 1) / full
        return body - chunks * UInt64(tagSize)
    }

    // MARK: - Streaming

    /// Seals as bytes arrive; `finish()` writes the last, flagged chunk.
    final class Writer {
        let header: Data
        private let key: SymmetricKey
        private let context: String
        private let fileNonce: Data
        private var index: UInt32 = 0
        private var pending = Data()

        init(key: SymmetricKey, context: String) throws {
            var nonce = Data(count: 8)
            let status = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
            guard status == errSecSuccess else { throw Failure.corrupt }
            self.key = key
            self.context = context
            self.fileNonce = nonce
            self.header = SealedFile.magic + nonce
        }

        /// Sealed bytes ready to write for `data` — whole chunks only; the rest waits.
        func append(_ data: Data) throws -> Data {
            pending.append(data)
            var out = Data()
            // Keep at least one byte back: the final chunk must be the one `finish` seals.
            while pending.count > SealedFile.chunkSize {
                out.append(try sealChunk(pending.prefix(SealedFile.chunkSize), final: false))
                pending.removeFirst(SealedFile.chunkSize)
            }
            return out
        }

        func finish() throws -> Data {
            defer { pending = Data() }
            return try sealChunk(pending, final: true)
        }

        fileprivate func sealChunk(_ chunk: Data, final: Bool) throws -> Data {
            let nonce = try AES.GCM.Nonce(data: fileNonce + SealedFile.bigEndian(index))
            let box = try AES.GCM.seal(chunk, using: key, nonce: nonce,
                                       authenticating: SealedFile.associatedData(context, index, final))
            index += 1
            return box.ciphertext + box.tag
        }
    }

    /// Clear pieces of a sealed file, one chunk at a time.
    final class Reader {
        private let handle: FileHandle
        private let key: SymmetricKey
        private let context: String
        private let fileNonce: Data
        private let fileSize: UInt64
        private var index: UInt32 = 0
        private var done = false

        init(url: URL, key: SymmetricKey, context: String) throws {
            handle = try FileHandle(forReadingFrom: url)
            fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            guard let header = try handle.read(upToCount: SealedFile.headerSize),
                  header.count == SealedFile.headerSize, header.prefix(4) == SealedFile.magic else {
                try? handle.close()
                throw Failure.notSealed
            }
            fileNonce = header.suffix(8)
            self.key = key
            self.context = context
        }

        deinit { try? handle.close() }

        /// The next clear chunk, or `nil` after the last.
        func next() throws -> Data? {
            guard !done else { return nil }
            guard let chunk = try handle.read(upToCount: SealedFile.chunkSize + SealedFile.tagSize),
                  chunk.count >= SealedFile.tagSize else { throw Failure.truncated }
            let final = try handle.offset() == fileSize
            let clear = try SealedFile.openChunk(chunk, index: index, final: final,
                                                 fileNonce: fileNonce, key: key, context: context)
            index += 1
            done = final
            return clear
        }
    }

    // MARK: - Chunks

    fileprivate static func openChunk(
        _ chunk: Data, index: UInt32, final: Bool, fileNonce: Data, key: SymmetricKey, context: String
    ) throws -> Data {
        guard chunk.count >= tagSize else { throw Failure.truncated }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: fileNonce + bigEndian(index)),
            ciphertext: chunk.dropLast(tagSize),
            tag: chunk.suffix(tagSize)
        )
        return try AES.GCM.open(box, using: key, authenticating: associatedData(context, index, final))
    }

    fileprivate static func associatedData(_ context: String, _ index: UInt32, _ final: Bool) -> Data {
        Data(context.utf8) + bigEndian(index) + Data([final ? 1 : 0])
    }

    fileprivate static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

// MARK: - Files

/// Files this device keeps at rest: written sealed, read through, and a clear file from an older
/// build sealed in place the first time it is met. One place, so media, thumbnails and history
/// transfer cannot disagree on the format.
enum AtRestFiles {

    /// Seal and write atomically. `false` — and nothing written — when there is no store key:
    /// a file in the clear is what this replaced.
    @discardableResult
    static func write(_ data: Data, to url: URL, context: String) -> Bool {
        guard let key = LocalStoreKey.current(),
              let sealed = try? SealedFile.seal(data, under: key, context: context) else {
            Log.error("AtRestFiles: no store key — \(url.lastPathComponent.prefix(12)) not written", category: "Storage")
            return false
        }
        do {
            try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            Log.error("AtRestFiles: write failed for \(url.lastPathComponent.prefix(12)): \(error)", category: "Storage")
            return false
        }
    }

    /// The clear contents. A clear file from before sealing is returned and sealed in place.
    static func read(_ url: URL, context: String) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard SealedFile.isSealed(data) else {
            write(data, to: url, context: context)
            return data
        }
        guard let key = LocalStoreKey.current() else { return nil }
        do {
            return try SealedFile.open(data, under: key, context: context)
        } catch {
            Log.error("AtRestFiles: \(url.lastPathComponent.prefix(12)) does not open: \(error)", category: "Storage")
            return nil
        }
    }

    /// Clear size, sealed or not.
    static func clearSize(of url: URL) -> UInt64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return SealedFile.isSealed(fileAt: url)
            ? SealedFile.plaintextSize(ofSealedFileSize: UInt64(size))
            : UInt64(size)
    }

    /// Seal a clear file in place, streaming — a video is not loaded whole to do it.
    @discardableResult
    static func sealInPlace(_ url: URL, context: String) -> Bool {
        guard !SealedFile.isSealed(fileAt: url), let key = LocalStoreKey.current(),
              let input = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? input.close() }
        let part = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).sealing")
        do {
            let writer = try SealedFile.Writer(key: key, context: context)
            FileManager.default.createFile(atPath: part.path, contents: nil,
                                           attributes: Self.protectionAttributes)
            let output = try FileHandle(forWritingTo: part)
            defer { try? output.close() }
            try output.write(contentsOf: writer.header)
            while let piece = try input.read(upToCount: SealedFile.chunkSize), !piece.isEmpty {
                try output.write(contentsOf: try writer.append(piece))
            }
            try output.write(contentsOf: try writer.finish())
            try output.close()
            _ = try FileManager.default.replaceItemAt(url, withItemAt: part)
            return true
        } catch {
            try? FileManager.default.removeItem(at: part)
            Log.error("AtRestFiles: sealing \(url.lastPathComponent.prefix(12)) failed: \(error)", category: "Storage")
            return false
        }
    }

    /// Clear chunks of a file, sealed or not: history transfer streams media without holding a
    /// video whole.
    static func chunks(of url: URL, context: String) throws -> AnyIterator<Data> {
        if SealedFile.isSealed(fileAt: url) {
            guard let key = LocalStoreKey.current() else { throw SealedFile.Failure.corrupt }
            let reader = try SealedFile.Reader(url: url, key: key, context: context)
            return AnyIterator { try? reader.next() }
        }
        let handle = try FileHandle(forReadingFrom: url)
        return AnyIterator {
            guard let piece = try? handle.read(upToCount: SealedFile.chunkSize), !piece.isEmpty else {
                try? handle.close()
                return nil
            }
            return piece
        }
    }

    static var protectionAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        [:]
        #endif
    }
}
