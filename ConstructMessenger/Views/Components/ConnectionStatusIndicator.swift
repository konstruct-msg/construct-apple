//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Compact connection status indicator (colored dot in navigation bar)
struct ConnectionStatusIndicator: View {
    @ObservedObject var connectionManager = ConnectionStatusManager.shared
    @State private var animationScale: CGFloat = 1.0
    @State private var introScale: CGFloat = 0.0

    var body: some View {
        ZStack {
            // Pulsing outer ring while connecting
            if connectionManager.connectionStatus == .connecting {
                Circle()
                    .stroke(Color.orange.opacity(0.35), lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .scaleEffect(animationScale)
            }

            // Main status dot
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
                .animation(.easeInOut(duration: 0.3), value: indicatorColor)
        }
        .frame(width: 20, height: 20)
        .scaleEffect(introScale)
        .onAppear {
            startPulse()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                introScale = 1.0
            }
        }
        .onChange(of: connectionManager.connectionStatus) { startPulse() }
    }

    private var indicatorColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:    return .green
        case .disconnected: return .red
        case .connecting:   return .orange
        case .unknown:      return .gray
        }
    }

    private func startPulse() {
        guard connectionManager.connectionStatus == .connecting else {
            animationScale = 1.0
            return
        }
        animationScale = 1.0
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            animationScale = 1.4
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack { Text("Connected:"); ConnectionStatusIndicator() }
        HStack { Text("Disconnected:"); Circle().fill(.red).frame(width: 10, height: 10) }
        HStack { Text("Connecting:"); Circle().fill(.orange).frame(width: 10, height: 10) }
    }
    .padding()
}
