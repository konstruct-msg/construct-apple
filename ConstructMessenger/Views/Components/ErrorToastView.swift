//
//  ErrorToastView.swift
//  Construct Messenger
//
//  A reusable floating toast that reads from ErrorRouter.
//  Attach to any view hierarchy with .errorToast():
//
//      ContentView()
//          .errorToast()
//
//  The toast slides in from the top, auto-dismisses info/warning,
//  and shows a retry button for critical errors.
//

import SwiftUI

// MARK: - Toast View

struct ErrorToastView: View {

    @ObservedObject private var router = ErrorRouter.shared

    var body: some View {
        if let error = router.currentError {
            toast(for: error)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: router.errorToken)
                .zIndex(999)
        }
    }

    @ViewBuilder
    private func toast(for error: AppError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: error))
                .foregroundColor(tintColor(for: error))
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "An error occurred")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle = error.recoveryActionTitle, router.recoveryHandler != nil {
                // Show action button only when a recovery handler is registered
                Button(actionTitle) {
                    router.executeRecovery()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(tintColor(for: error))
            } else {
                Button {
                    router.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        // Large tap target so the X is easy to hit on mobile
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            Color.AppBackground.primary
                .opacity(0.97)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tintColor(for: error).opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // Swipe up anywhere on the banner to dismiss
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -20 {
                        router.dismiss()
                    }
                }
        )
    }

    // MARK: - Helpers

    private func tintColor(for error: AppError) -> Color {
        switch error.severity {
        case .info:     return .blue
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    private func iconName(for error: AppError) -> String {
        switch error {
        case .network, .streamDisconnected:  return "wifi.slash"
        case .sessionInitFailed,
             .decryptionFailed,
             .cryptoCoreUnavailable,
             .keyOperationFailed:            return "lock.trianglebadge.exclamationmark"
        case .mediaUploadFailed,
             .mediaDownloadFailed,
             .mediaOptimizationFailed:       return "photo.badge.exclamationmark"
        case .validation:                    return "exclamationmark.triangle"
        case .authFailed, .sessionExpired:   return "person.badge.key"
        case .unknown:                       return "exclamationmark.circle"
        }
    }
}

// MARK: - ViewModifier

private struct ErrorToastModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            ErrorToastView()
        }
    }
}

extension View {
    /// Attach a global error toast overlay driven by ErrorRouter.shared.
    func errorToast() -> some View {
        modifier(ErrorToastModifier())
    }
}
