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
            .animation(.easeInOut(duration: 0.3), value: connectionManager.connectionStatus)
            .onAppear { startPulseIfNeeded() }
            .onChange(of: connectionManager.connectionStatus) { startPulseIfNeeded() }
    }

    private var labelText: String {
        switch connectionManager.connectionStatus {
        case .connected:            return "X25519+Kyber768"
        case .connecting, .unknown: return "Connecting..."
        case .disconnected:         return "Offline"
        }
    }

    private var labelColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:            return Color.Construct.accent
        case .connecting, .unknown: return Color.Construct.textDim
        case .disconnected:         return Color(hex: 0xE05555).opacity(0.85)
        }
    }

    private func startPulseIfNeeded() {
        let isConnected = connectionManager.connectionStatus == .connected
        if isConnected {
            withAnimation(.easeOut(duration: 0.3)) { textOpacity = 1 }
        } else {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                textOpacity = 0.4
            }
        }
    }
}

#Preview {
    ConnectionStatusIndicator()
        .padding()
        .background(Color.Construct.bg)
}
