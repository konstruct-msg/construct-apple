//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Text-only connection status shown in the chats list navigation bar.
///
/// Behaviour:
/// - Connecting / Offline → always visible (pulses)
/// - Secure → appears on connection, fades out after 10 s
///   On reconnect the cycle restarts so the user is notified again.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared

    @State private var textOpacity: Double = 1
    /// Controls whether the "Secure" label is rendered at all.
    /// We use a separate bool so the view collapses to zero width when hidden
    /// rather than just being transparent (avoids dead space in nav bar).
    @State private var secureVisible: Bool = true
    @State private var hideTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if connectionManager.connectionStatus == .connected {
                if secureVisible {
                    Text(NSLocalizedString("connection_status_secure", comment: ""))
                        .opacity(textOpacity)
                }
            } else {
                Text(labelText)
                    .opacity(textOpacity)
            }
        }
        .font(ConstructFont.mono(12, weight: .medium))
        .foregroundStyle(labelColor)
        .animation(.easeInOut(duration: 0.6), value: connectionManager.connectionStatus)
        .onAppear { handleStatusChange(connectionManager.connectionStatus) }
        .onChange(of: connectionManager.connectionStatus) { _, newStatus in
                handleStatusChange(newStatus)
            }
    }

    private var labelText: String {
        switch connectionManager.connectionStatus {
        case .connected:            return NSLocalizedString("connection_status_secure", comment: "")
        case .connecting, .unknown: return NSLocalizedString("connection_status_connecting", comment: "")
        case .disconnected:         return NSLocalizedString("connection_status_offline", comment: "")
        }
    }

    private var labelColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:            return Color.Construct.accent.opacity(0.75)
        case .connecting, .unknown: return Color.Construct.textDim
        case .disconnected:         return Color(hex: 0xE05555).opacity(0.75)
        }
    }

    private func handleStatusChange(_ status: ConnectionStatusManager.ConnectionStatus) {
        hideTask?.cancel()
        hideTask = nil

        switch status {
        case .connected:
            // Snap visible, full opacity, then schedule auto-hide.
            secureVisible = true
            withAnimation(.easeOut(duration: 0.4)) { textOpacity = 1 }
            hideTask = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 s
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeIn(duration: 0.8)) { textOpacity = 0 }
                }
                try? await Task.sleep(nanoseconds: 800_000_000) // wait for fade
                guard !Task.isCancelled else { return }
                await MainActor.run { secureVisible = false }
            }

        case .connecting, .unknown:
            secureVisible = true
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                textOpacity = 0.65
            }

        case .disconnected:
            secureVisible = true
            withAnimation(.easeOut(duration: 0.3)) { textOpacity = 1 }
        }
    }
}

#Preview {
    ConnectionStatusIndicator()
        .padding()
        .background(Color.Construct.bg)
}
