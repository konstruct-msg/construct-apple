//
//  DesktopEmptyStateView.swift
//  Construct Desktop
//
//  Empty-state panel — CT terminal aesthetic.
//  Three protocol cards connected by ASCII lines; sharp borders, JetBrains Mono.
//

import SwiftUI

struct DesktopEmptyStateView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Wordmark
            VStack(spacing: 4) {
                Text("KONSTRUCT")
                    .font(CTFont.bold(20))
                    .foregroundStyle(Color.CT.text)
                    .tracking(8)

                Text("post-quantum secure messaging")
                    .font(CTFont.regular(10))
                    .foregroundStyle(Color.CT.textDim)
                    .tracking(2)
            }
            .padding(.bottom, 40)

            // Protocol stack — three ASCII cards connected by lines
            HStack(alignment: .top, spacing: 0) {
                protocolCard(
                    label: "TRANSPORT",
                    rows: [("PROTOCOL", "gRPC"), ("SECURITY", "TLS 1.3"), ("DELIVERY", "BiDi Stream")],
                    isAccent: false
                )
                connectorLine
                protocolCard(
                    label: "KEY EXCHANGE",
                    rows: [("ALGORITHM", "PQXDH"), ("CLASSICAL", "X25519"), ("PQ", "Kyber-768")],
                    isAccent: true
                )
                connectorLine
                protocolCard(
                    label: "MESSAGING",
                    rows: [("RATCHET", "Double Ratchet"), ("CIPHER", "AES-256-GCM"), ("FWD. SECRECY", "Per-msg")],
                    isAccent: false
                )
            }

            Spacer()

            // Bottom shortcut hint row
            HStack(spacing: 12) {
                shortcutHint("⌘N",  "new conversation")
                Text("·").foregroundStyle(Color.CT.textDim)
                shortcutHint("⌘K",  "quick open")
                Text("·").foregroundStyle(Color.CT.textDim)
                shortcutHint("⌘⌥N", "add contact")
                Text("·").foregroundStyle(Color.CT.textDim)
                shortcutHint("⌘,",  "settings")
            }
            .font(CTFont.regular(11))
            .foregroundStyle(Color.CT.textDim)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ctBackground()
    }

    // MARK: - ASCII protocol card

    private func protocolCard(
        label: String,
        rows: [(String, String)],
        isAccent: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header line: ┌── LABEL ──┐
            HStack(spacing: 0) {
                Text(isAccent ? "[" : "╔")
                    .font(CTFont.bold(9))
                    .foregroundStyle(isAccent ? Color.CT.accent : Color.CT.textDim)
                Text(" \(label) ")
                    .font(CTFont.bold(9))
                    .foregroundStyle(isAccent ? Color.CT.accent : Color.CT.text)
                    .tracking(1.5)
                Text(isAccent ? "]" : "╗")
                    .font(CTFont.bold(9))
                    .foregroundStyle(isAccent ? Color.CT.accent : Color.CT.textDim)
            }
            .padding(.bottom, 10)

            // Rows
            VStack(alignment: .leading, spacing: 11) {
                ForEach(rows, id: \.0) { key, value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key)
                            .font(CTFont.regular(8))
                            .foregroundStyle(Color.CT.textDim)
                            .tracking(1.5)
                        Text(value)
                            .font(CTFont.regular(11))
                            .foregroundStyle(isAccent ? Color.CT.accent : Color.CT.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(width: 148)
        .background(
            Rectangle()
                .fill(isAccent ? Color.CT.accent.opacity(0.04) : Color.CT.bgMsg)
        )
        .overlay(
            Rectangle()
                .stroke(isAccent ? Color.CT.accent.opacity(0.5) : Color.CT.textDim.opacity(0.35), lineWidth: 1)
        )
    }

    private var connectorLine: some View {
        Rectangle()
            .fill(Color.CT.noise)
            .frame(width: 16, height: 1)
            .padding(.top, 22)
    }

    // MARK: - Shortcut badge

    private func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text("[\(key)]")
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.accent)
            Text(label)
                .font(CTFont.regular(11))
                .foregroundStyle(Color.CT.textDim)
        }
    }
}

#Preview {
    DesktopEmptyStateView()
        .frame(width: 640, height: 520)
}



