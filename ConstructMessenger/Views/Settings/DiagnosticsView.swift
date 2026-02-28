//
//  DiagnosticsView.swift
//  ConstructMessenger
//
//  In-app log viewer + share sheet for debugging without Xcode.
//

import SwiftUI

struct DiagnosticsView: View {
    @State private var logText: String = ""
    @State private var isSharing = false
    @State private var archiveURL: URL?
    @State private var logSize: String = ""
    @State private var isClearing = false

    var body: some View {
        List {
            // MARK: - Status
            Section {
                HStack {
                    Label("Log collection", systemImage: "doc.text")
                    Spacer()
                    Text(LogCollector.shared.isEnabled ? "Active" : "Off")
                        .foregroundStyle(LogCollector.shared.isEnabled ? Color.AppStatus.success : .secondary)
                        .font(.footnote)
                }
                if !logSize.isEmpty {
                    HStack {
                        Label("Size", systemImage: "internaldrive")
                        Spacer()
                        Text(logSize).foregroundStyle(.secondary).font(.footnote)
                    }
                }
            }

            // MARK: - Actions
            Section {
                Button {
                    shareArchive()
                } label: {
                    Label("Share logs", systemImage: "square.and.arrow.up")
                }
                .disabled(!LogCollector.shared.isEnabled)

                Button(role: .destructive) {
                    clearLogs()
                } label: {
                    Label("Clear logs", systemImage: "trash")
                }
                .disabled(!LogCollector.shared.isEnabled)
            }

            // MARK: - Recent Logs
            if !logText.isEmpty {
                Section("Recent logs (tail)") {
                    ScrollView {
                        Text(logText)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .textSelection(.enabled)
                    }
                    .frame(height: 340)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { refresh() }
        .sheet(isPresented: $isSharing) {
            if let url = archiveURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    // MARK: - Helpers

    private func refresh() {
        let bytes = LogCollector.shared.getTotalLogSize()
        if bytes > 0 {
            logSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        } else {
            logSize = "empty"
        }

        // Show last ~200 lines of current log
        let files = LogCollector.shared.getAllLogFiles()
        if let first = files.first,
           let raw = try? String(contentsOf: first, encoding: .utf8) {
            let lines = raw.components(separatedBy: "\n")
            logText = lines.suffix(200).joined(separator: "\n")
        }
    }

    private func shareArchive() {
        do {
            archiveURL = try LogCollector.shared.createLogArchive()
            isSharing = true
        } catch {
            Log.error("Failed to create log archive: \(error)", category: "Diagnostics")
        }
    }

    private func clearLogs() {
        LogCollector.shared.clearLogs()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { refresh() }
    }
}

// MARK: - UIActivityViewController wrapper

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack { DiagnosticsView() }
}
