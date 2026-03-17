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
//    ErrorRouter.shared.report(error, recovery: { [weak self] in self?.retry() })
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

    /// Recovery handler registered by the caller. Non-nil means the toast button is shown.
    @Published private(set) var recoveryHandler: (() -> Void)?

    // MARK: - Auto-dismiss
    private var dismissTask: Task<Void, Never>?
    private let autoDismissDelay: TimeInterval = 4

    // MARK: - Report

    /// Report any Error. Maps to AppError, checks shouldDisplay, logs, publishes.
    func report(_ error: Error, context: String = "", recovery: (() -> Void)? = nil,
                file: String = #file, line: Int = #line) {
        let appError = AppError.from(error)
        report(appError, context: context, recovery: recovery, file: file, line: line)
    }

    /// Report a typed AppError directly with an optional one-shot recovery action.
    /// - Parameter recovery: Closure invoked when the user taps the toast action button.
    ///   Pass `nil` to show the toast without an action button.
    func report(_ error: AppError, context: String = "", recovery: (() -> Void)? = nil,
                file: String = #file, line: Int = #line) {
        let ctx = context.isEmpty ? "" : " [\(context)]"
        Log.error("ErrorRouter\(ctx): \(error.errorDescription ?? String(describing: error))",
                  category: "ErrorRouter")

        guard error.shouldDisplay else { return }

        currentError = error
        recoveryHandler = recovery
        errorToken += 1

        // Auto-dismiss info/warning after a delay only when there is no recovery action —
        // if there IS a retry/reconnect handler, keep the toast visible until the user acts.
        if error.severity != .critical && recovery == nil {
            scheduleDismiss()
        }
    }

    // MARK: - Recovery

    /// Called when the user taps the toast action button. Runs the handler then dismisses.
    func executeRecovery() {
        let handler = recoveryHandler
        dismiss()
        handler?()
    }

    // MARK: - Dismiss

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentError = nil
        recoveryHandler = nil
    }

    // MARK: - Private

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.autoDismissDelay ?? 4) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }
}
