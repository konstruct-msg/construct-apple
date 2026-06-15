//
//  DebugMetricsOverlay.swift
//  Construct Messenger
//
//  Debug-build overlay showing real-time performance metrics.
//  Activated by shake gesture. Only the overlay itself is compiled in DEBUG only.
//

import SwiftUI

#if DEBUG

// MARK: - Overlay

struct DebugMetricsOverlay: View {

    @State private var vm = DebugMetricsViewModel()
@Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().background(Color.orange.opacity(0.4))
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summarySection
                        Divider().background(Color.orange.opacity(0.3))
                        recentEventsSection
                    }
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundColor(.orange)
        .onAppear { vm.refresh() }
    }

    private var header: some View {
        HStack {
            Text("// DEBUG METRICS")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundColor(.orange)
            Spacer()
            Button(action: { vm.clear() }) {
                Text("CLEAR").foregroundColor(.orange.opacity(0.6))
            }
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill").foregroundColor(.orange)
            }
        }
        .padding(10)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("── AVERAGES (last 20) ──").foregroundColor(.orange.opacity(0.6))

            metricRow("Msg receive→display",
                      avg: vm.avgReceiveDisplay,
                      p95: vm.p95ReceiveDisplay,
                      unit: "ms")
            metricRow("Decrypt",
                      avg: vm.avgDecrypt,
                      p95: vm.p95Decrypt,
                      unit: "ms")
            metricRow("Session init",
                      avg: vm.avgSessionInit,
                      p95: vm.p95SessionInit,
                      unit: "ms")
            metricRow("gRPC connect",
                      avg: vm.avgGRPCConnect,
                      p95: nil,
                      unit: "ms")
            metricRow("VEIL proxy start",
                      avg: vm.avgVEILStart,
                      p95: nil,
                      unit: "ms")

            Text("── FAILOVER (last 200) ──").foregroundColor(.orange.opacity(0.6))
                .padding(.top, 6)
            HStack {
                Text("Stream ICE failover")
                    .frame(width: 160, alignment: .leading)
                    .foregroundColor(.orange.opacity(0.8))
                Text("count: \(vm.streamFastFailoverCount)")
                    .foregroundColor(vm.streamFastFailoverCount == 0 ? .orange.opacity(0.7) : .yellow)
            }
        }
    }

    private func metricRow(_ label: String, avg: Double?, p95: Double?, unit: String) -> some View {
        HStack {
            Text(label)
                .frame(width: 160, alignment: .leading)
                .foregroundColor(.orange.opacity(0.8))
            if let avg {
                Text(String(format: "avg: %.0f%@", avg, unit))
                    .foregroundColor(avg < 100 ? .orange : avg < 500 ? .yellow : .red)
                    .frame(width: 80)
            } else {
                Text("avg: —").foregroundColor(.gray).frame(width: 80)
            }
            if let p95 {
                Text(String(format: "p95: %.0f%@", p95, unit))
                    .foregroundColor(p95 < 200 ? .orange : p95 < 800 ? .yellow : .red)
            } else {
                Text("p95: —").foregroundColor(.gray)
            }
        }
    }

    private var recentEventsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("── RECENT EVENTS ──").foregroundColor(.orange.opacity(0.6))
            ForEach(vm.recentSamples) { sample in
                HStack {
                    Text(sample.formattedDuration)
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(sample.durationMs < 150 ? .orange : sample.durationMs < 500 ? .yellow : .red)
                    Text(sample.label)
                        .foregroundColor(.orange.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class DebugMetricsViewModel {

    var recentSamples: [LatencySample] = []
    var avgReceiveDisplay: Double? = nil
    var p95ReceiveDisplay: Double? = nil
    var avgDecrypt: Double? = nil
    var p95Decrypt: Double? = nil
    var avgSessionInit: Double? = nil
    var p95SessionInit: Double? = nil
    var avgGRPCConnect: Double? = nil
    var avgVEILStart: Double? = nil
    var streamFastFailoverCount: Int = 0


    private var refreshTimer: Timer?

    init() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        MainActor.assumeIsolated { refreshTimer?.invalidate() }
    }

    func refresh() {
        let m = PerformanceMetrics.shared
        recentSamples = m.recentSamples(limit: 30).reversed()
        avgReceiveDisplay = m.averageLatency(for: "envelope_arrived→ui_displayed")
        p95ReceiveDisplay = m.p95Latency(for: "envelope_arrived→ui_displayed")
        avgDecrypt = m.averageLatency(for: "decrypt_start→decrypt_end")
        p95Decrypt = m.p95Latency(for: "decrypt_start→decrypt_end")
        avgSessionInit = m.averageLatency(for: "session_init_start→session_init_end")
        p95SessionInit = m.p95Latency(for: "session_init_start→session_init_end")
        avgGRPCConnect = m.averageLatency(for: "grpc_connect_start→grpc_connect_end")
        avgVEILStart = m.averageLatency(for: "veil_proxy_start_begin→veil_proxy_start_end")
        streamFastFailoverCount = m.count(event: .streamOpenFastFailover, last: 200)

    }

    func clear() {
        PerformanceMetrics.shared.clearAll()
        refresh()
    }
}

// MARK: - View Modifier

struct DebugMetricsModifier: ViewModifier {
    @State private var showOverlay = true

    func body(content: Content) -> some View {
        content
            .onShake {
                showOverlay.toggle()
            }
            .overlay {
                if showOverlay {
                    DebugMetricsOverlay(isPresented: $showOverlay)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: showOverlay)
                }
            }
    }
}

extension View {
    /// Attach debug metrics overlay (shake to show). No-op in Release builds.
    func debugMetricsOverlay() -> some View {
        modifier(DebugMetricsModifier())
    }
}

// MARK: - Shake gesture

#if os(iOS)
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceShook, object: nil)
        }
    }
}
#endif

extension Notification.Name {
    static let deviceShook = Notification.Name("cc.konstruct.messenger.deviceShook")
}

private struct ShakeViewModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .deviceShook)) { _ in
            action()
        }
    }
}

extension View {
    fileprivate func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeViewModifier(action: action))
    }
}

#else

// Release: no-op modifier
extension View {
    func debugMetricsOverlay() -> some View { self }
}

#endif
