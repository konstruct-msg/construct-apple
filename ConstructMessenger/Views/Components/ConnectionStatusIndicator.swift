//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI

/// Compact connection status indicator (colored dot in navigation bar)
struct ConnectionStatusIndicator: View {
    @ObservedObject var webSocketManager = WebSocketManager.shared

    var body: some View {
        ZStack {
            // Outer ring for reconnecting animation
            if case .reconnecting = webSocketManager.connectionStatus {
                Circle()
                    .stroke(indicatorColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 16, height: 16)
                    .scaleEffect(animationScale)
                    .animation(
                        Animation.easeInOut(duration: 1.0)
                            .repeatForever(autoreverses: true),
                        value: animationScale
                    )
            }

            // Main status dot
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)
        }
        .frame(width: 20, height: 20)
    }

    private var indicatorColor: Color {
        switch webSocketManager.connectionStatus {
        case .connected:
            return .green
        case .disconnected:
            return .red
        case .reconnecting:
            return .orange
        }
    }

    @State private var animationScale: CGFloat = 1.0

    init() {
        _animationScale = State(initialValue: 1.3)
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack {
            Text("Connected:")
            ConnectionStatusIndicator()
        }

        HStack {
            Text("Disconnected:")
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
        }

        HStack {
            Text("Reconnecting:")
            Circle()
                .fill(Color.orange)
                .frame(width: 10, height: 10)
        }
    }
    .padding()
}
