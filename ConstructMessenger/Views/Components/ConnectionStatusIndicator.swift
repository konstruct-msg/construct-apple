//
//  ConnectionStatusIndicator.swift
//  Construct Messenger
//

import SwiftUI

/// Compact connection indicator for the chat-list header — a single dot, no text.
///
/// - **Connecting** (incl. cold start / unknown): a soft pulsing dot.
/// - **Connected**: a brief accent glow that then fades away, so a healthy connection adds no
///   permanent chrome (the calm the old dot had).
/// - **Disconnected**: a steady danger dot — but only *after* a first successful connect, so a
///   cold start reads as "connecting", never a scary "Disconnected" flash.
///
/// No transport/VEIL is disclosed here (silent-transport-ui decision): the dot is identical whether
/// the connection is direct or routed through a relay.
struct ConnectionStatusIndicator: View {
    var connectionManager = ConnectionStatusManager.shared

    @State private var visible = true
    @State private var dotScale: CGFloat = 1
    @State private var dotOpacity: Double = 1
    @State private var hasConnectedOnce = false
    @State private var hideTask: Task<Void, Never>? = nil

    private enum DisplayState { case connecting, connected, disconnected, paused }

    private var displayState: DisplayState {
        if connectionManager.isStreamPaused { return .paused }
        switch connectionManager.connectionStatus {
        case .connected:            return .connected
        case .connecting, .unknown: return .connecting
        // Before the first successful connect a drop is just "still trying" — never alarm on launch.
        case .disconnected:         return hasConnectedOnce ? .disconnected : .connecting
        }
    }

    private var dotColor: Color {
        switch displayState {
        case .connected:    return Color.CT.accent
        case .connecting:   return Color.CT.textDim
        case .disconnected: return Color.CT.danger.opacity(0.8)
        case .paused:       return Color.CT.textDim.opacity(0.45)
        }
    }

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .scaleEffect(dotScale)
            .opacity(visible ? dotOpacity : 0)
            .shadow(color: displayState == .connected ? Color.CT.accent.opacity(0.7) : .clear, radius: 4)
            .animation(.easeInOut(duration: 0.4), value: dotColor)
            .onAppear { apply(displayState) }
            .onChange(of: connectionManager.connectionStatus) { _, newStatus in
                if newStatus == .connected { hasConnectedOnce = true }
                apply(displayState)
            }
            .onChange(of: connectionManager.isStreamPaused) { _, _ in apply(displayState) }
    }

    private func apply(_ state: DisplayState) {
        hideTask?.cancel()
        hideTask = nil
        visible = true

        switch state {
        case .connecting:
            dotOpacity = 1
            dotScale = 1
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                dotScale = 0.6
                dotOpacity = 0.5
            }

        case .connected:
            // Stop the pulse, settle to a full accent dot, glow, then fade out.
            withAnimation(.easeOut(duration: 0.35)) {
                dotScale = 1
                dotOpacity = 1
            }
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.8)) { dotOpacity = 0 }
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard !Task.isCancelled else { return }
                visible = false
            }

        case .disconnected:
            withAnimation(.easeOut(duration: 0.3)) {
                dotScale = 1
                dotOpacity = 1
            }

        case .paused:
            withAnimation(.easeOut(duration: 0.3)) {
                dotScale = 1
                dotOpacity = 0.6
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        ConnectionStatusIndicator()
    }
    .padding()
    .background(Color.CT.bg)
}
