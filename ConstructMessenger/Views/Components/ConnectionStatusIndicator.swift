//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Terminal-style connection status badge.
///
/// Shows the actual transport path (RELAY host · protocol or DIRECT)
/// derived from IceProxyManager.currentTrafficPath plus gRPC stream state.
/// Pulses when connecting; auto-hides after 4 s when connected.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared
    @ObservedObject var iceProxy = IceProxyManager.shared

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
        switch connectionManager.connectionStatus {
        case .connected:
            return "> \(trafficLabel) · [✓]"
        case .connecting, .unknown:
            return "> \(trafficLabel) · ···"
        case .disconnected:
            return "> OFFLINE"
        }
    }

    private var trafficLabel: String {
        switch iceProxy.currentTrafficPath {
        case .direct:
            return "DIRECT"
        case .icePrimary(let host):
            // Strip port if present, keep only hostname
            let hostname = host.components(separatedBy: ":").first ?? host
            return "RELAY: \(hostname) · TLS+OBFS4"
        case .iceRelay(let address):
            let hostname = address.components(separatedBy: ":").first ?? address
            return "RELAY: \(hostname) · OBFS4"
        case .iceWebTunnel(let relay):
            let hostname = relay.components(separatedBy: ":").first ?? relay
            return "RELAY: \(hostname) · WEBTUNNEL"
        case .iceCooldown:
            return "DIRECT · RECOVERING"
        case .iceConnecting:
            return "ICE STARTING"
        }
    }

    private var labelColor: Color {
        switch connectionManager.connectionStatus {
        case .connected:
            switch iceProxy.currentTrafficPath {
            case .direct:     return Color.CT.textDim
            case .icePrimary: return Color.CT.accent
            case .iceRelay:   return Color.CT.accentDim
            case .iceWebTunnel: return Color.CT.accent
            case .iceCooldown, .iceConnecting: return Color.CT.textDim
            }
        case .connecting, .unknown:
            return Color.CT.textDim
        case .disconnected:
            return Color(hex: 0xE05555).opacity(0.8)
        }
    }

    // MARK: - Visibility logic

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
