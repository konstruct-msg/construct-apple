//
//  ServerInfoBanner.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import SwiftUI

/// Debug баннер для показа информации о подключении (только в Debug режиме)
struct ServerInfoBanner: View {
    @ObservedObject var connectionStatusManager = ConnectionStatusManager.shared

    var body: some View {
        if AppConstants.enableDebugLogging {
            VStack(spacing: 4) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(connectionStatusManager.connectionStatus.displayText)
                        .font(.caption2)
                        .fontWeight(.semibold)

                    Spacer()
                }

                Text(Bundle.main.object(forInfoDictionaryKey: "GRPC_HOST") as? String ?? "ams.konstruct.cc")
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
        switch connectionStatusManager.connectionStatus {
        case .connected:
            return Color.AppStatus.success
        case .disconnected:
            return .red
        case .connecting:
            return .orange
        case .unknown:
            return .gray
        }
    }
}
