//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Text-based connection status shown in the chats list navigation bar.
/// Connected → accent blue label. Other states show explicit status text.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared
    @State private var dotOpacity: Double = 1

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .opacity(dotOpacity)

            Text(labelText)
                .font(ConstructFont.mono(12, weight: .medium))
                .foregroundStyle(labelColor)
        }
        .animation(.easeInOut(duration: 0.3), value: connectionManager.connectionStatus)
        .onAppear { startPulseIfNeeded() }
        .onChange(of: connectionManager.connectionStatus) { startPulseIfNeeded() }
    }

    // MARK: - State-driven properties

    private var labelText: String {
        switch connectionManager.connectionStatus {
        case .connected:    return "Construct"
        case .connecting:   return "Connecting..."
        case .disconnected: return "Offline"
        case .unknown:      return "Connecting..."
        }
    }

    private var labelColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:              return Color.Construct.accent
        case .connecting, .unknown:   return Color.Construct.textDim
        case .disconnected:           return Color(hex: 0xE05555).opacity(0.85)
        }
    }

    private var dotColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:              return Color.Construct.accent.opacity(0.8)
        case .connecting, .unknown:   return Color.Construct.textDim.opacity(0.6)
        case .disconnected:           return Color(hex: 0xE05555).opacity(0.7)
        }
    }

    // MARK: - Pulse animation for non-connected states

    private func startPulseIfNeeded() {
        let isActive = connectionManager.connectionStatus != .connected
        if isActive {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                dotOpacity = 0.25
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                dotOpacity = 1
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ConnectionStatusIndicator()
    }
    .padding()
    .background(Color.Construct.bg)
}
