//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Compact connection status indicator (flat square in navigation bar)
struct ConnectionStatusIndicator: View {
    @ObservedObject var connectionManager = ConnectionStatusManager.shared
    @State private var blinkOpacity: Double = 1.0
    @State private var introScale: CGFloat = 0.0

    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
                .opacity(connectionManager.connectionStatus == .connecting ? blinkOpacity : 1.0)
                .animation(.easeInOut(duration: 0.3), value: indicatorColor)

            Text(statusLabel)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(indicatorColor)
                .animation(.easeInOut(duration: 0.3), value: indicatorColor)
        }
        .scaleEffect(introScale)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { introScale = 1.0 }
            startBlink()
        }
        .onChange(of: connectionManager.connectionStatus) { startBlink() }
    }

    private var indicatorColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:    return Color.AppBrand.second
        case .disconnected: return Color.AppBrand.third
        case .connecting:   return Color.AppBrand.third
        case .unknown:      return Color.AppText.secondary
        }
    }

    private var statusLabel: String {
        switch connectionManager.connectionStatus {
        case .connected:    return "ONLINE"
        case .disconnected: return "OFFLINE"
        case .connecting:   return "CONNECTING"
        case .unknown:      return "UNKNOWN"
        }
    }

    private func startBlink() {
        guard connectionManager.connectionStatus == .connecting else {
            blinkOpacity = 1.0
            return
        }
        blinkOpacity = 1.0
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            blinkOpacity = 0.2
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
