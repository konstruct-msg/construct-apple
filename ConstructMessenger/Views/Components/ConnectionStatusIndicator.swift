//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Compact connection status badge for the chat list header.
///
/// States: Connected (auto-hides, except on VEIL) / Connecting... (with phase) / Paused / Disconnected.
/// When VEIL is active the connected badge stays visible permanently.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared
    @ObservedObject var veilManager = VeilProxyManager.shared

    @State private var textOpacity: Double = 1
    @State private var visible: Bool = true
    @State private var hideTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if visible {
                Text(connectionManager.statusIndicatorText)
                    .opacity(textOpacity)
            }
        }
        .font(CTFont.regular(11))
        .foregroundStyle(labelColor)
        .animation(.easeInOut(duration: 0.5), value: connectionManager.connectionStatus)
        .onAppear { handleStatusChange(connectionManager.connectionStatus) }
        .onChange(of: connectionManager.connectionStatus) { _, newStatus in
            handleStatusChange(newStatus)
        }
        .onChange(of: connectionManager.isStreamPaused) { _, isPaused in
            handlePauseChange(isPaused)
        }
        .onChange(of: veilManager.isRunning) { _, isRunning in
            if case .connected = connectionManager.connectionStatus {
                if isRunning {
                    // VEIL activated while connected — cancel hide timer, stay visible.
                    hideTask?.cancel()
                    hideTask = nil
                    visible = true
                    withAnimation(.easeOut(duration: 0.4)) { textOpacity = 1 }
                } else {
                    // VEIL stopped while connected — start normal hide timer.
                    handleStatusChange(.connected)
                }
            }
        }
    }

    private var labelColor: Color {
        if connectionManager.isStreamPaused {
            return Color.CT.textDim.opacity(0.45)
        }
        switch connectionManager.connectionStatus {
        case .connected:
            return veilManager.isRunning ? Color.CT.accent : Color.CT.textDim
        case .connecting, .unknown:
            return Color.CT.textDim
        case .disconnected:
            return Color.CT.danger.opacity(0.7)
        }
    }

    // MARK: - Visibility / Animation

    private func handleStatusChange(_ status: ConnectionStatusManager.ConnectionStatus) {
        guard !connectionManager.isStreamPaused else { return }
        hideTask?.cancel()
        hideTask = nil

        switch status {
        case .connected:
            visible = true
            withAnimation(.easeOut(duration: 0.4)) { textOpacity = 1 }
            // Keep indicator visible permanently when VEIL is active.
            if !veilManager.isRunning {
                hideTask = Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation(.easeIn(duration: 0.8)) { textOpacity = 0 }
                    }
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { visible = false }
                }
            }

        case .connecting, .unknown:
            visible = true
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                textOpacity = 0.55
            }

        case .disconnected:
            visible = true
            withAnimation(.easeOut(duration: 0.3)) { textOpacity = 1 }
        }
    }

    private func handlePauseChange(_ isPaused: Bool) {
        hideTask?.cancel()
        hideTask = nil
        visible = true
        if isPaused {
            withAnimation(.easeOut(duration: 0.3)) { textOpacity = 0.45 }
        } else {
            handleStatusChange(connectionManager.connectionStatus)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ConnectionStatusIndicator()
    }
    .padding()
    .background(Color.CT.bg)
}
