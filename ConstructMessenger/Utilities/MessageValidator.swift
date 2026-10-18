//
//  MessageValidator.swift
//  Construct Messenger
//
//  Message validation utilities for size limits and content checks
//

import Foundation

// MARK: - Validation Error
enum MessageValidationError: LocalizedError, UserFacingError {
    case textTooLarge(currentSize: Int, maxSize: Int)
    case fileTooLarge(fileName: String, currentSize: Int64, maxSize: Int64)
    case unsupportedFileType(fileName: String, extension: String)
    case totalSizeTooLarge(currentSize: Int64, maxSize: Int64)
    case emptyMessage
    case selfSend

    /// The sizes are formatted here and nothing else is carried in: a file name is the person's.
    /// `textTooLarge` is said without its numbers — its callers measure in characters or in
    /// bytes, and a file size is neither.
    var userText: UserText {
        switch self {
        case .textTooLarge:
            return UserText("validation_text_too_large")
        case .fileTooLarge(let name, let current, let max):
            return UserText(
                "validation_file_too_large", name,
                MessageSizeLimits.formatFileSize(current), MessageSizeLimits.formatFileSize(max)
            )
        case .unsupportedFileType(_, let ext):
            return UserText("validation_unsupported_type", ext)
        case .totalSizeTooLarge(let current, let max):
            return UserText(
                "validation_total_too_large",
                MessageSizeLimits.formatFileSize(current), MessageSizeLimits.formatFileSize(max)
            )
        case .emptyMessage:
            return UserText("validation_empty")
        case .selfSend:
            return UserText("validation_self_send")
        }
    }

    var errorDescription: String? { userText.resolved }
}

// MARK: - Message Validator
struct MessageValidator {

    // MARK: - Text Validation

    /// Validates text message size
    /// - Parameter text: The message text to validate
    /// - Throws: MessageValidationError if text is invalid
    static func validateText(_ text: String) throws {
        // Check if empty
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageValidationError.emptyMessage
        }

        // Check size: limit by character count (UI) and byte count (wire)
        guard text.count <= MessageSizeLimits.maxTextCharacters else {
            throw MessageValidationError.textTooLarge(
                currentSize: text.count,
                maxSize: MessageSizeLimits.maxTextCharacters
            )
        }
        let textBytes = text.utf8.count
        guard textBytes <= MessageSizeLimits.maxPlaintextMessageBytes else {
            throw MessageValidationError.textTooLarge(
                currentSize: textBytes,
                maxSize: MessageSizeLimits.maxPlaintextMessageBytes
            )
        }
    }

    // MARK: - Split Validation

    /// Splits `text` into chunks of at most `maxChars` characters, splitting
    /// preferentially at newline → sentence → word boundaries.
    static func splitIntoChunks(_ text: String, maxChars: Int = MessageSizeLimits.maxTextCharacters) -> [String] {
        guard text.count > maxChars else { return [text] }

        var chunks: [String] = []
        var remaining = Substring(text)

        while !remaining.isEmpty {
            if remaining.count <= maxChars {
                chunks.append(String(remaining))
                break
            }

            let endIndex = remaining.index(remaining.startIndex, offsetBy: maxChars)
            let searchRange = remaining.startIndex..<endIndex
            var splitIndex: String.Index = endIndex

            // Prefer split at newline
            if let r = remaining.range(of: "\n", options: .backwards, range: searchRange) {
                splitIndex = r.upperBound
            // Then sentence boundary
            } else if let r = remaining.range(of: ". ", options: .backwards, range: searchRange) {
                splitIndex = r.upperBound
            } else if let r = remaining.range(of: "! ", options: .backwards, range: searchRange) {
                splitIndex = r.upperBound
            } else if let r = remaining.range(of: "? ", options: .backwards, range: searchRange) {
                splitIndex = r.upperBound
            // Then word boundary
            } else if let r = remaining.range(of: " ", options: .backwards, range: searchRange) {
                splitIndex = r.upperBound
            }
            // Hard cut as last resort

            let chunk = remaining[..<splitIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            remaining = remaining[splitIndex...].drop(while: { $0 == " " || $0 == "\n" })
        }

        return chunks
    }

    // MARK: - Caption Validation

    /// Validates an optional media/file caption (may be empty, but must not exceed maxCaptionCharacters).
    static func validateCaption(_ caption: String) throws {
        guard caption.count <= MessageSizeLimits.maxCaptionCharacters else {
            throw MessageValidationError.textTooLarge(
                currentSize: caption.count,
                maxSize: MessageSizeLimits.maxCaptionCharacters
            )
        }
    }

    // MARK: - File Validation

    /// Validates a single file attachment
    /// - Parameters:
    ///   - fileURL: URL to the file
    ///   - fileName: Optional custom file name
    /// - Throws: MessageValidationError if file is invalid
    /// - Returns: the file's size, so a caller has no reason to read it again.
    @discardableResult
    static func validateFile(at fileURL: URL, fileName: String? = nil) throws -> Int64 {
        let name = fileName ?? fileURL.lastPathComponent
        let fileExtension = fileURL.pathExtension

        // Check if file type is supported
        guard MessageSizeLimits.isFileTypeSupported(fileExtension) else {
            throw MessageValidationError.unsupportedFileType(
                fileName: name,
                extension: fileExtension
            )
        }

        guard let fileSize = try size(of: fileURL) else {
            throw MessageValidationError.fileTooLarge(
                fileName: name,
                currentSize: 0,
                maxSize: MessageSizeLimits.maxUploadBytes
            )
        }

        let maxSize = MessageSizeLimits.maxUploadBytes
        guard fileSize <= maxSize else {
            throw MessageValidationError.fileTooLarge(
                fileName: name,
                currentSize: fileSize,
                maxSize: maxSize
            )
        }
        return fileSize
    }

    /// A file's size, read with access to it. A file picked from Files or iCloud Drive is
    /// security-scoped: read without asking, it answers "you don't have permission" (Cocoa 257).
    /// Until 2026-10-15 its size was read so in three places — the check at the pick, the check
    /// at the send, the pending bubble — and a document from iCloud Drive could not be sent. A
    /// file of the app's own answers false to the ask and reads as before. Read it here only.
    static func size(of fileURL: URL) throws -> Int64? {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    // MARK: - Combined Validation

    /// Validates a message with text and optional file attachments
    /// - Parameters:
    ///   - text: Message text (can be empty if there are attachments)
    ///   - fileURLs: Array of file URLs to attach
    /// - Throws: MessageValidationError if message is invalid
    static func validateMessage(text: String, fileURLs: [URL] = []) throws {
        var totalSize: Int64 = 0

        // Validate text if present
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validateText(text)
            totalSize += Int64(text.utf8.count)
        }

        // Validate each file
        for fileURL in fileURLs {
            totalSize += try validateFile(at: fileURL)
        }

        // Check if message has content (text or files)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fileURLs.isEmpty {
            throw MessageValidationError.emptyMessage
        }

        // Check total size
        guard totalSize <= MessageSizeLimits.maxTotalMessageBytes else {
            throw MessageValidationError.totalSizeTooLarge(
                currentSize: totalSize,
                maxSize: MessageSizeLimits.maxTotalMessageBytes
            )
        }
    }
}
