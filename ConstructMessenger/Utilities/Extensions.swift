//
//  Extensions.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation

extension Date {
    var timestamp: Int64 {
        Int64(self.timeIntervalSince1970)
    }

    static func from(timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}

extension String {
    var isValidUsername: Bool {
        let regex = "^[a-zA-Z0-9_]{3,30}$"
        return NSPredicate(format: "SELF MATCHES %@", regex).evaluate(with: self)
    }
}

extension Array {
    /// Safely retrieves an element at the specified index.
    ///
    /// - Parameter index: The index of the element to retrieve.
    /// - Returns: The element at the specified index, or `nil` if the index is out of bounds.
    func get(at index: Int) -> Element? {
        guard index >= 0, index < count else {
            return nil
        }
        return self[index]
    }
}

// MARK: - String + Markdown stripping

extension String {
    /// Returns a plain-text version of the string with inline Markdown markers removed.
    /// Used for chat list preview text where rendered formatting is not needed.
    static func strippingMarkdown(_ text: String) -> String {
        var s = text
        // Bold: **text** or __text__
        s = s.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
        // Italic: *text* or _text_  (single marker)
        s = s.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<!_)_(?!_)(.+?)(?<!_)_(?!_)"#, with: "$1", options: .regularExpression)
        // Inline code: `text`
        s = s.replacingOccurrences(of: #"`(.+?)`"#, with: "$1", options: .regularExpression)
        // Markdown links: [label](url) → label
        s = s.replacingOccurrences(of: #"\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)
        return s
    }
}

// MARK: - Error + user-facing message

import GRPCCore

extension Error {
    /// Returns a human-readable message suitable for display in the UI.
    /// Extracts the server message from gRPC RPCError instead of the useless
    /// "The operation couldn't be completed. (GRPCCore.RPCError error N.)" string.
    var userFacingMessage: String {
        if let rpcError = self as? RPCError {
            let msg = rpcError.message
            if !msg.isEmpty { return msg }
            return "Server error (code \(rpcError.code.rawValue))"
        }
        return localizedDescription
    }
}

// MARK: - NSManagedObjectContext helpers

import CoreData

extension NSManagedObjectContext {
    func saveOrThrow(category: String = "CoreData", file: String = #file, line: Int = #line) throws {
        guard hasChanges else { return }
        let location = "\(file.split(separator: "/").last ?? ""):\(line)"
        PerformanceMetrics.shared.coreDataSaveStart(label: location)
        do {
            try save()
            PerformanceMetrics.shared.coreDataSaveEnd(label: location)
        } catch {
            PerformanceMetrics.shared.coreDataSaveFailed(label: location)
            Log.error("Core Data save failed (\(location)): \(error)", category: category)
            throw error
        }
    }

    /// Saves the context and logs any error. Use instead of `try? save()` in
    /// service-layer code where a silent failure would lose message or session data.
    func saveAndLog(category: String = "CoreData", file: String = #file, line: Int = #line) {
        do {
            try saveOrThrow(category: category, file: file, line: line)
        } catch {
            // Already logged in saveOrThrow.
        }
    }
}

// MARK: - Async retry with backoff

/// Retry an async throwing closure up to `maxAttempts` times.
/// Waits `backoff` seconds after the first failure, `backoff*2` after the second, etc.
/// Only retries when `retryIf` returns true for the thrown error.
func withRetry<T>(
    maxAttempts: Int,
    backoff: TimeInterval = 1.0,
    retryIf: (Error) -> Bool = { _ in true },
    label: String = "operation",
    operation: () async throws -> T
) async throws -> T {
    var lastError: Error?
    for attempt in 1...max(1, maxAttempts) {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt < maxAttempts && retryIf(error) {
                let delay = backoff * pow(2.0, Double(attempt - 1))
                Log.debug("\(label) attempt \(attempt) failed (\(error.localizedDescription)), retrying in \(String(format: "%.1f", delay))s", category: "Retry")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                Log.error("\(label) failed after \(attempt) attempt(s): \(error)", category: "Retry")
                throw error
            }
        }
    }
    // lastError is always non-nil: every loop iteration that doesn't return sets it in the catch block.
    throw lastError ?? CancellationError()
}

// MARK: - Platform-agnostic SwiftUI view modifiers

import SwiftUI

extension View {
    /// `.textInputAutocapitalization(.never)` on iOS; no-op on macOS.
    @ViewBuilder func autocapNever() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// `.keyboardType(.numberPad)` on iOS; no-op on macOS.
    @ViewBuilder func numberPadKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
