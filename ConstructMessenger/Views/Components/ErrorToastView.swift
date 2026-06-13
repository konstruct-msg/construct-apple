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
            
            Text(icon(for: error))
                .font(CTFont.bold(14))
                .foregroundColor(tintColor(for: error))
                .lineLimit(1).fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                Text(error.errorDescription ?? "An error occurred")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.text)
                    .lineLimit(2)

                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle = error.recoveryActionTitle, router.recoveryHandler != nil {
                Button(actionTitle) {
                    router.executeRecovery()
                }
                .font(CTFont.regular(13))
                .foregroundColor(tintColor(for: error))
            } else {
                Button {
                    router.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.textDim)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                        .lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color.CT.bgMsg)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tintColor(for: error).opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
        case .info:     return Color.CT.accent
        case .warning:  return .orange
        case .critical: return Color.CT.danger
        }
    }
    
    private func icon(for error: AppError) -> Image {
        switch error {
        case .network, .streamDisconnected:
            return Image(systemName: "wifi.slash")
        case .sessionInitFailed, .decryptionFailed,
             .cryptoCoreUnavailable, .keyOperationFailed:
            return Image(systemName: "exclamationmark.triangle.fill")
        case .mediaUploadFailed, .mediaDownloadFailed,
                .mediaOptimizationFailed:
            return Image(systemName: "exclamationmark.icloud.fill")
        case .validation:
            return Image(systemName: "exclamationmark.bubble.fill")
        case .authFailed, .sessionExpired:
            return Image(systemName: "lock.rotation")
        case .unknown:
            return Image(systemName: "exclamationmark.bubble.fill")
        }
    }

    @available(*, unavailable)
    private func iconName(for error: AppError) -> String { "" }
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
