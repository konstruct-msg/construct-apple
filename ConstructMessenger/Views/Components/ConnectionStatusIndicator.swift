//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Compact connection status badge for the chat list header.
///
/// Three states: Connected / Connecting... / Disconnected
/// Shows a snowflake (*) when routed through ICE relay.
/// Auto-hides after 4 s when connected.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared
    @ObservedObject var iceManager = IceProxyManager.shared

    @State private var textOpacity: Double = 1
    @State private var visible: Bool = true
    @State private var hideTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if visible {
                Text(labelText)
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
    }

    // MARK: - Label

    private var labelText: String {
        let status: String
        switch connectionManager.connectionStatus {
        case .connected:
            status = NSLocalizedString("connected", comment: "")
        case .connecting, .unknown:
            status = NSLocalizedString("status_connecting", comment: "")
        case .disconnected:
            status = NSLocalizedString("disconnected", comment: "")
        }
        if case .connected = connectionManager.connectionStatus, iceManager.isRunning {
            return "> \(status) \(CTSymbol.star8)"
        }
        return "> \(status)"
    }

    private var labelColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:
            return iceManager.isRunning ? Color.CT.accent : Color.CT.textDim
        case .connecting, .unknown:
            return Color.CT.textDim
        case .disconnected:
            return Color.CT.danger.opacity(0.7)
        }
    }

    // MARK: - Visibility

    private func handleStatusChange(_ status: ConnectionStatusManager.ConnectionStatus) {
        hideTask?.cancel()
        hideTask = nil

        switch status {
        case .connected:
            visible = true
            withAnimation(.easeOut(duration: 0.4)) { textOpacity = 1 }
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
}

#Preview {
    ConnectionStatusIndicator()
        .padding()
        .background(Color.CT.bg)
}
