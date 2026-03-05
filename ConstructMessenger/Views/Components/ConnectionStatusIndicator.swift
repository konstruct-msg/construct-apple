//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Compact connection status dot shown in the chats list navigation bar.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Pulsing ring — only shown while connecting
            if connectionManager.connectionStatus == .connecting {
                Circle()
                    .stroke(Color.orange.opacity(0.35), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(isPulsing ? 1.45 : 1.0)
                    .animation(
                        isPulsing
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: isPulsing
                    )
            }

            // Status dot — color transitions smoothly
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 20, height: 20)
        .onAppear { updatePulse() }
        .onChange(of: connectionManager.connectionStatus) { updatePulse() }
    }

    private var indicatorColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:    return Color.AppStatus.success
        case .disconnected: return .red
        case .connecting:   return .orange
        case .unknown:      return .gray
        }
    }

    private func updatePulse() {
        let shouldPulse = connectionManager.connectionStatus == .connecting
        guard isPulsing != shouldPulse else { return }
        if shouldPulse {
            // Short delay so the ring renders first, then starts expanding
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isPulsing = true
            }
        } else {
            isPulsing = false
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack { Text("Connected:");    ConnectionStatusIndicator() }
        HStack { Text("Disconnected:"); Circle().fill(.red).frame(width: 10, height: 10) }
        HStack { Text("Connecting:");   Circle().fill(.orange).frame(width: 10, height: 10) }
    }
    .padding()
}
