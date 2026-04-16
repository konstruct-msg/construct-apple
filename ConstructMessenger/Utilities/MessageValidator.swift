//
//  MessageValidator.swift
//  Construct Messenger
//
//  Message validation utilities for size limits and content checks
//

import Foundation

// MARK: - Validation Error
enum MessageValidationError: LocalizedError {
    case textTooLarge(currentSize: Int, maxSize: Int)
    case fileTooLarge(fileName: String, currentSize: Int64, maxSize: Int64)
    case unsupportedFileType(fileName: String, extension: String)
    case totalSizeTooLarge(currentSize: Int64, maxSize: Int64)
    case emptyMessage
    case selfSend

    var errorDescription: String? {
        switch self {
        case .textTooLarge(let current, let max):
            return "Message text is too large (\(MessageSizeLimits.formatFileSize(Int64(current)))). Maximum allowed: \(MessageSizeLimits.formatFileSize(Int64(max)))"
        case .fileTooLarge(let name, let current, let max):
            return "File '\(name)' is too large (\(MessageSizeLimits.formatFileSize(current))). Maximum allowed: \(MessageSizeLimits.formatFileSize(max))"
        case .unsupportedFileType(let name, let ext):
            return "File type '.\(ext)' is not supported for file '\(name)'"
        case .totalSizeTooLarge(let current, let max):
            return "Total message size is too large (\(MessageSizeLimits.formatFileSize(current))). Maximum allowed: \(MessageSizeLimits.formatFileSize(max))"
        case .emptyMessage:
            return "Message cannot be empty"
        case .selfSend:
            return "Cannot send encrypted messages to yourself"
        }
    }
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
    static func validateFile(at fileURL: URL, fileName: String? = nil) throws {
        let name = fileName ?? fileURL.lastPathComponent
        let fileExtension = fileURL.pathExtension

        // Check if file type is supported
        guard MessageSizeLimits.isFileTypeSupported(fileExtension) else {
            throw MessageValidationError.unsupportedFileType(
                fileName: name,
                extension: fileExtension
            )
        }

        // Check file size
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw MessageValidationError.fileTooLarge(
                fileName: name,
                currentSize: 0,
                maxSize: MessageSizeLimits.maxFileAttachmentBytes
            )
        }

        let maxSize = MessageSizeLimits.maxSizeForFileType(fileExtension)
        guard fileSize <= maxSize else {
            throw MessageValidationError.fileTooLarge(
                fileName: name,
                currentSize: fileSize,
                maxSize: maxSize
            )
        }
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
            try validateFile(at: fileURL)

            // Add to total size
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
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

    // MARK: - Helper Methods

    /// Returns a user-friendly warning if file size is approaching the limit
    /// - Parameter fileURL: URL to the file
    /// - Returns: Warning message if file is > 80% of limit, nil otherwise
    static func sizeWarning(for fileURL: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int64 else {
            return nil
        }

        let fileExtension = fileURL.pathExtension
        let maxSize = MessageSizeLimits.maxSizeForFileType(fileExtension)
        let percentage = Double(fileSize) / Double(maxSize)

        if percentage > 0.8 {
            return "File size is \(MessageSizeLimits.formatFileSize(fileSize)) (\(Int(percentage * 100))% of \(MessageSizeLimits.formatFileSize(maxSize)) limit)"
        }

        return nil
    }
}
