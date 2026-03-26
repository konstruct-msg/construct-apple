//
//  DesktopEmptyStateView.swift
//  Construct Desktop
//
//  The first thing an authenticated user sees.
//  Communicates the technology stack without being gimmicky:
//  three protocol cards arranged as a security chain, monospaced
//  labels, accent glow — precision-tool aesthetic.
//

import SwiftUI

struct DesktopEmptyStateView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Wordmark
            VStack(spacing: 6) {
                Text("CONSTRUCT")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesktopTheme.textPrimary)
                    .tracking(8)

                Text("post-quantum secure messaging")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(DesktopTheme.textTertiary)
                    .tracking(2)
            }
            .padding(.bottom, 44)

            // Protocol stack — three cards connected by lines
            HStack(alignment: .top, spacing: 0) {
                protocolCard(
                    label: "TRANSPORT",
                    rows: [
                        ("PROTOCOL", "gRPC"),
                        ("SECURITY", "TLS 1.3"),
                        ("DELIVERY", "BiDi Stream"),
                    ]
                )

                connectorLine

                protocolCard(
                    label: "KEY EXCHANGE",
                    rows: [
                        ("ALGORITHM", "PQXDH"),
                        ("CLASSICAL", "X25519"),
                        ("POST-QUANTUM", "Kyber-1024"),
                    ],
                    isCenter: true
                )

                connectorLine

                protocolCard(
                    label: "MESSAGING",
                    rows: [
                        ("RATCHET", "Double Ratchet"),
                        ("CIPHER", "AES-256-GCM"),
                        ("FWD. SECRECY", "Per-message"),
                    ]
                )
            }

            Spacer()

            // Bottom hint
            HStack(spacing: 6) {
                shortcutKey("⌘N")
                Text("New conversation")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.textTertiary)

                Text("·")
                    .foregroundStyle(DesktopTheme.textTertiary)

                shortcutKey("⌘F")
                Text("Find chat")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.textTertiary)

                Text("·")
                    .foregroundStyle(DesktopTheme.textTertiary)

                shortcutKey("⌘,")
                Text("Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(DesktopTheme.textTertiary)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesktopTheme.backgroundPrimary)
    }

    // MARK: - Protocol card

    private func protocolCard(
        label: String,
        rows: [(String, String)],
        isCenter: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack(spacing: 6) {
                if isCenter {
                    Circle()
                        .fill(DesktopTheme.accent)
                        .frame(width: 6, height: 6)
                        .shadow(color: DesktopTheme.accent.opacity(0.5), radius: 4)
                } else {
                    Circle()
                        .fill(DesktopTheme.textTertiary)
                        .frame(width: 5, height: 5)
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isCenter ? DesktopTheme.accent : DesktopTheme.textSecondary)
                    .tracking(2)
            }
            .padding(.bottom, 10)

            // Rows — vertical: key label above value
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows, id: \.0) { key, value in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key)
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DesktopTheme.textTertiary)
                            .tracking(1.5)
                        Text(value)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(isCenter ? DesktopTheme.accent.opacity(0.9) : DesktopTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(DesktopTheme.backgroundElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isCenter
                                ? DesktopTheme.accent.opacity(0.2)
                                : DesktopTheme.separator,
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isCenter ? DesktopTheme.accent.opacity(0.06) : .clear,
                    radius: 16
                )
        )
        .frame(width: 148)
    }

    // MARK: - Connector

    private var connectorLine: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(DesktopTheme.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 23)
        .frame(width: 16)
    }

    // MARK: - Keyboard shortcut badge

    private func shortcutKey(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(DesktopTheme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(DesktopTheme.backgroundElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(DesktopTheme.separator, lineWidth: 1)
                    )
            )
    }
}

#Preview {
    DesktopEmptyStateView()
        .frame(width: 600, height: 500)
}
