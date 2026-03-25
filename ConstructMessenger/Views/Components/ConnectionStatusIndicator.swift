//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Text-only connection status shown in the chats list navigation bar.
/// Connected → shows the active crypto suite in accent blue.
/// Other states → show plain status text in muted colors.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared
    @State private var textOpacity: Double = 1

    var body: some View {
        Text(labelText)
            .font(ConstructFont.mono(12, weight: .medium))
            .foregroundStyle(labelColor)
            .opacity(textOpacity)
            .animation(.easeInOut(duration: 0.5), value: connectionManager.connectionStatus)
            .onAppear { startPulseIfNeeded() }
            .onChange(of: connectionManager.connectionStatus) { startPulseIfNeeded() }
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

    private func startPulseIfNeeded() {
        let isConnected = connectionManager.connectionStatus == .connected
        if isConnected {
            withAnimation(.easeOut(duration: 0.5)) { textOpacity = 1 }
        } else {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                textOpacity = 0.7
            }
        }
    }
}

#Preview {
    ConnectionStatusIndicator()
        .padding()
        .background(Color.Construct.bg)
}
