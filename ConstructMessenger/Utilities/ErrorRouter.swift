//
//  ErrorRouter.swift
//  Construct Messenger
//
//  Single entry point for reporting and displaying errors.
//  ViewModels call ErrorRouter.shared.report(_:) instead of setting
//  their own errorMessage properties.
//
//  Usage:
//    ErrorRouter.shared.report(error)
//    ErrorRouter.shared.report(AppError.network(.disconnected), context: "stream")
//

import Foundation
import Combine

@MainActor
final class ErrorRouter: ObservableObject {

    // MARK: - Singleton
    static let shared = ErrorRouter()
    private init() {}

    // MARK: - Published state

    /// The error currently presented to the user. nil = no banner visible.
    @Published private(set) var currentError: AppError?

    /// Incremented on each new error so Views can detect repeated same-type errors.
    @Published private(set) var errorToken: Int = 0

    // MARK: - Auto-dismiss
    private var dismissTask: Task<Void, Never>?
    private let autoDismissDelay: TimeInterval = 4

    // MARK: - Report

    /// Report any Error.  Maps to AppError, checks shouldDisplay, logs, publishes.
    func report(_ error: Error, context: String = "", file: String = #file, line: Int = #line) {
        let appError = AppError.from(error)
        report(appError, context: context, file: file, line: line)
    }

    /// Report a typed AppError directly.
    func report(_ error: AppError, context: String = "", file: String = #file, line: Int = #line) {
        let ctx = context.isEmpty ? "" : " [\(context)]"
        Log.error("ErrorRouter\(ctx): \(error.errorDescription ?? String(describing: error))",
                  category: "ErrorRouter")

        guard error.shouldDisplay else { return }

        currentError = error
        errorToken += 1

        // Auto-dismiss info/warning after a delay; leave critical until user acts
        if error.severity != .critical {
            scheduleDismiss()
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentError = nil
    }

    // MARK: - Private

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.autoDismissDelay ?? 4) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.currentError = nil
        }
    }
}
