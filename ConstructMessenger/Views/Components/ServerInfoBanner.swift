//
//  ServerInfoBanner.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

/// Debug баннер для показа информации о подключении (только в Debug режиме)
struct ServerInfoBanner: View {
    @ObservedObject var webSocketManager = WebSocketManager.shared

    var body: some View {
        if AppConstants.enableDebugLogging {
            VStack(spacing: 4) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(webSocketManager.connectionStatus.displayText)
                        .font(.caption2)
                        .fontWeight(.semibold)

                    Spacer()

//                    Text(ServerEnvironment.current.displayName)
//                        .font(.caption2)
//                        .foregroundColor(.secondary)
                }

                Text(APIConstants.activeServerURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }

    private var statusColor: Color {
        switch webSocketManager.connectionStatus {
        case .connected:
            return .green
        case .disconnected:
            return .red
        case .reconnecting:
            return .orange
        }
    }
}
