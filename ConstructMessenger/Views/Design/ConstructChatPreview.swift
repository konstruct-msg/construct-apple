// ConstructChatPreview.swift
// Standalone design prototype — uses ConstructTheme.
// NOT wired to any live data. Open in Xcode Canvas to preview.
// Ref: /Users/maximeliseyev/Documents/Konstruct/ASCII_style_design.md

import SwiftUI

// MARK: - Message Models

private struct PreviewMessage: Identifiable {
    let id = UUID()
    let text: String
    let isOutgoing: Bool
    let time: String
    let status: Status
    enum Status { case sent, delivered, read }
}

// MARK: - Message Row

private struct MessageRow: View {
    let msg: PreviewMessage

    var body: some View {
        if msg.isOutgoing { outgoing } else { incoming }
    }

    private var incoming: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(msg.text)
                    .font(CTFont.regular(14))
                    .foregroundColor(Color.CT.text)
                    .ctMessageBlock(outgoing: false)
                Text(msg.time)
                    .font(CTFont.regular(10))
                    .foregroundColor(Color.CT.textDim)
            }
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 12)
    }

    private var outgoing: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 2) {
                Text(msg.text)
                    .font(CTFont.regular(14))
                    .foregroundColor(.white)
                    .ctMessageBlock(outgoing: true)
                HStack(spacing: 4) {
                    Text(msg.time)
                        .font(CTFont.regular(10))
                        .foregroundColor(Color.CT.textDim)
                    Text(statusGlyph)
                        .font(CTFont.regular(10))
                        .foregroundColor(msg.status == .read ? Color.CT.accent : Color.CT.textDim)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var statusGlyph: String {
        switch msg.status {
        case .sent:      return CTSymbol.ok
        case .delivered: return CTSymbol.delivered
        case .read:      return CTSymbol.read
        }
    }
}

// MARK: - Input Bar

private struct InputBar: View {
    @State private var text = ""
    @State private var cursorOn = true

    var body: some View {
        HStack(spacing: 12) {
            Text(CTSymbol.media)
                .font(CTFont.regular(14))
                .foregroundColor(Color.CT.textDim)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    HStack(spacing: 0) {
                        Text("type a message")
                            .font(CTFont.regular(14))
                            .foregroundColor(Color.CT.textDim)
                        Text(CTSymbol.cursor)
                            .font(CTFont.bold(14))
                            .foregroundColor(Color.CT.accentDim)
                            .opacity(cursorOn ? 1 : 0)
                            .animation(.easeInOut(duration: 0.5).repeatForever(), value: cursorOn)
                            .onAppear { cursorOn.toggle() }
                    }
                }
                TextField("", text: $text)
                    .font(CTFont.regular(14))
                    .foregroundColor(Color.CT.text)
                    .tint(Color.CT.accent)
            }
            .frame(maxWidth: .infinity)

            Text(CTSymbol.send)
                .font(CTFont.bold(14))
                .foregroundColor(Color.CT.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .ctBorderTop()
    }
}

// MARK: - Chat Screen Preview

private struct ChatScreenPreview: View {
    private let messages: [PreviewMessage] = [
        .init(text: "What time is the event today\nat the office?",
              isOutgoing: false, time: "10:30", status: .read),
        .init(text: "It starts at 7pm but if you're\navailable can you come in early\nto help set up?",
              isOutgoing: true, time: "10:34", status: .read),
        .init(text: "Sure, I can be there by 5pm.\nShould I bring anything?",
              isOutgoing: false, time: "10:36", status: .read),
        .init(text: "Just yourself 👍",
              isOutgoing: true, time: "10:37", status: .delivered),
        .init(text: "On my way",
              isOutgoing: false, time: "10:52", status: .read),
    ]

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise().ignoresSafeArea()

            VStack(spacing: 0) {
                // Nav bar — chat-specific layout with user name
                HStack(spacing: 10) {
                    Text(CTSymbol.back)
                        .font(CTFont.bold(14))
                        .foregroundColor(Color.CT.accent)
                    Text("<@axiom>")
                        .font(CTFont.bold(14))
                        .foregroundColor(Color.CT.text)
                    Spacer()
                    Text(CTSymbol.online)
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.accentDim)
                    Text(CTSymbol.menu)
                        .font(CTFont.bold(14))
                        .foregroundColor(Color.CT.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .ctBorderBottom()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        CTSystemMessage(text: "E2EE SESSION ACTIVE · RATCHET IN SYNC")
                        ForEach(messages) { msg in
                            MessageRow(msg: msg)
                        }
                    }
                    .padding(.vertical, 12)
                }

                InputBar()
            }
        }
    }
}

// MARK: - Chat List Row

private struct ChatListRow: View {
    let username: String
    let preview: String
    let time: String
    let unread: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                CTHexAvatar(
                    initials: String(username.prefix(2)),
                    size: .medium
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("<@\(username)>")
                            .font(CTFont.bold(14))
                            .foregroundColor(Color.CT.text)
                        Spacer()
                        Text(time)
                            .font(CTFont.regular(11))
                            .foregroundColor(Color.CT.textDim)
                    }
                    HStack {
                        Text(preview)
                            .font(CTFont.regular(12))
                            .foregroundColor(Color.CT.textDim)
                            .lineLimit(1)
                        Spacer()
                        if unread > 0 {
                            Text("[\(unread)]")
                                .font(CTFont.bold(11))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.CT.accent)
                                .clipShape(Rectangle())
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            CTSep()
        }
    }
}

// MARK: - Chats List Screen

private struct ChatsListPreview: View {
    private let chats = [
        (user: "axiom",    preview: "On my way",               time: "10:52", unread: 0),
        (user: "phantom",  preview: "Did you see the report?", time: "09:14", unread: 3),
        (user: "neo_rx",   preview: "Keys verified ✓",          time: "Вчера", unread: 0),
        (user: "construct",preview: "System message",           time: "Пн",    unread: 1),
    ]

    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise().ignoresSafeArea()

            VStack(spacing: 0) {
                // Status header
                VStack(alignment: .leading, spacing: 1) {
                    CTSystemMessage(text: "RELAY: ams.konstruct.cc · TLS+OBFS4")
                    CTSystemMessage(text: "SESSION STREAM ACTIVE · \(CTSymbol.add)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .ctBorderBottom()

                // Search bar
                HStack {
                    Text("[")
                        .font(CTFont.regular(14))
                        .foregroundColor(Color.CT.textDim)
                    Text("search\(CTSymbol.cursor)")
                        .font(CTFont.regular(14))
                        .foregroundColor(Color.CT.textDim)
                    Spacer()
                    Text("]")
                        .font(CTFont.regular(14))
                        .foregroundColor(Color.CT.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.CT.bgMsg)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(chats, id: \.user) { c in
                            ChatListRow(username: c.user, preview: c.preview,
                                        time: c.time, unread: c.unread)
                        }
                    }
                }

                CTTabBar(selected: .constant(0))
            }
        }
    }
}

// MARK: - Settings: Main

private struct SettingsMainPreview: View {
    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise().ignoresSafeArea()

            VStack(spacing: 0) {
                CTNavBar(title: "SETTINGS", trailingSymbol: nil)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Profile row → drill-down
                        HStack(spacing: 14) {
                            CTHexAvatar(initials: "AX", size: .large)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("<@axiom>")
                                    .font(CTFont.bold(15))
                                    .foregroundColor(Color.CT.text)
                                Text("\(CTSymbol.online) · keys \(CTSymbol.ok)")
                                    .font(CTFont.regular(11))
                                    .foregroundColor(Color.CT.accentDim)
                            }
                            Spacer()
                            Text(CTSymbol.forward)
                                .font(CTFont.bold(16))
                                .foregroundColor(Color.CT.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)

                        CTSep(style: .thick)

                        CTSettingsSectionHeader(title: "SECURITY")
                        CTSettingsRow(label: "keys & sessions", value: CTSymbol.forward, isAction: true)
                        CTSep()

                        CTSettingsSectionHeader(title: "NETWORK")
                        CTSettingsRow(label: "relay / transport", value: CTSymbol.forward, isAction: true)
                        CTSep()

                        CTSettingsSectionHeader(title: "NOTIFICATIONS")
                        CTSettingsRow(label: "push alerts",      value: "[ON]",  valueColor: Color.CT.accentDim)
                        CTSep()
                        CTSettingsRow(label: "voip calls",       value: "[ON]",  valueColor: Color.CT.accentDim)
                        CTSep()
                        CTSettingsRow(label: "message preview",  value: "[OFF]", valueColor: Color.CT.textDim)
                        CTSep()
                        CTSettingsRow(label: "sounds",           value: "[ON]",  valueColor: Color.CT.accentDim)
                        CTSep()

                        CTSettingsSectionHeader(title: "APPEARANCE")
                        CTSettingsRow(label: "theme",      value: "DARK [●]", valueColor: Color.CT.accentDim)
                        CTSep()
                        CTSettingsRow(label: "font size",  value: "14px")
                        CTSep()
                        CTSettingsRow(label: "noise",      value: "10% opacity")
                        CTSep()

                        CTSettingsSectionHeader(title: "DANGER ZONE")
                        CTSettingsRow(label: "clear sessions",  value: "[run \(CTSymbol.forward)]",    isAction: true)
                        CTSep()
                        CTSettingsRow(label: "delete account",  value: "[delete →]", isDestructive: true)
                        CTSep(style: .thick)

                        CTSystemMessage(text: "construct-messenger v0.9 · core v0.6")
                            .padding(.bottom, 20)
                    }
                }

                CTTabBar(selected: .constant(2))
            }
        }
    }
}

// MARK: - Settings: Security Detail

private struct SecurityDetailPreview: View {
    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise().ignoresSafeArea()

            VStack(spacing: 0) {
                CTNavBar(title: "SECURITY", showBack: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        CTSettingsSectionHeader(title: "IDENTITY KEYS")
                        CTSettingsRow(label: "IK algorithm",  value: "ED25519")
                        CTSep()
                        CTSettingsRow(label: "PQ algorithm",  value: "Kyber-1024")
                        CTSep()
                        CTSettingsRow(label: "key status",    value: "\(CTSymbol.ok) VERIFIED", valueColor: Color.CT.accentDim)
                        CTSep()
                        CTSettingsRow(label: "fingerprint",   value: "[show QR \(CTSymbol.forward)]", isAction: true)
                        CTSep()

                        // Fingerprint block
                        VStack(alignment: .leading, spacing: 6) {
                            CTSettingsSectionHeader(title: "KEY FINGERPRINT")
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(["3A:F2:11:9C:4B:E0:72:DA",
                                         "8F:C3:55:1A:B7:29:6E:04",
                                         "D1:40:88:3C:F9:71:2B:5A",
                                         "E6:0D:44:97:CB:16:73:8F"], id: \.self) { chunk in
                                    Text(chunk)
                                        .font(CTFont.bold(13))
                                        .foregroundColor(Color.CT.accentDim)
                                }
                            }
                            .padding(10)
                            .background(Color.CT.bgMsg)
                            .overlay(Rectangle().stroke(Color.CT.noise, lineWidth: 0.5))
                            .padding(.horizontal, 12)
                        }

                        CTSep()
                        CTSettingsSectionHeader(title: "DOUBLE RATCHET")
                        CTSettingsRow(label: "active sessions", value: "12")
                        CTSep()
                        CTSettingsRow(label: "SPK rotation",    value: "every 14d")
                        CTSep()
                        CTSettingsRow(label: "next rotation",   value: "in 3 days")
                        CTSep()
                        CTSettingsRow(label: "OTPK pool",       value: "48 / 100")
                        CTSep()
                        CTSettingsRow(label: "session list",    value: "[view \(CTSymbol.forward)]", isAction: true)
                        CTSep()

                        CTSettingsSectionHeader(title: "ACTIONS")
                        CTSettingsRow(label: "rotate SPK now",     value: "[run \(CTSymbol.forward)]",    isAction: true)
                        CTSep()
                        CTSettingsRow(label: "clear all sessions", value: "[clear →]", isDestructive: true)
                        CTSep(style: .thick)

                        CTSystemMessage(text: "PQXDH + Double Ratchet · post-quantum forward secrecy")
                            .padding(.bottom, 20)
                    }
                }
            }
        }
    }
}

// MARK: - Settings: Network Detail

private struct NetworkDetailPreview: View {
    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise().ignoresSafeArea()

            VStack(spacing: 0) {
                CTNavBar(title: "NETWORK", showBack: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        CTSettingsSectionHeader(title: "ACTIVE RELAY")
                        CTSettingsRow(label: "host",          value: "ams.konstruct.cc")
                        CTSep()
                        CTSettingsRow(label: "port",          value: "443")
                        CTSep()
                        CTSettingsRow(label: "transport",     value: "TLS + OBFS4",   valueColor: Color.CT.accentDim)
                        CTSep()
                        CTSettingsRow(label: "protocol",      value: "gRPC / binary", valueColor: Color.CT.accentDim)
                        CTSep()
                        CTSettingsRow(label: "latency",       value: "~38ms")
                        CTSep()
                        CTSettingsRow(label: "status",        value: "[[CONNECTED]]", valueColor: Color.CT.accentDim)
                        CTSep()

                        CTSettingsSectionHeader(title: "FALLBACK RELAY")
                        CTSettingsRow(label: "host",          value: "msk.konstruct.cc")
                        CTSep()
                        CTSettingsRow(label: "port",          value: "443")
                        CTSep()
                        CTSettingsRow(label: "transport",     value: "TLS + OBFS4")
                        CTSep()
                        CTSettingsRow(label: "status",        value: "standby")
                        CTSep()

                        CTSettingsSectionHeader(title: "BEHAVIOUR")
                        CTSettingsRow(label: "bg grace",       value: "5s")
                        CTSep()
                        CTSettingsRow(label: "auto-reconnect", value: "[ON]", valueColor: Color.CT.accentDim)
                        CTSep()
                        CTSettingsRow(label: "cert pinning",   value: "[ON]", valueColor: Color.CT.accentDim)
                        CTSep(style: .thick)

                        CTSystemMessage(text: "all traffic obfuscated · no metadata leakage")
                            .padding(.bottom, 20)
                    }
                }
            }
        }
    }
}

// MARK: - Settings: Profile Detail

private struct ProfileDetailPreview: View {
    var body: some View {
        ZStack {
            Color.CT.bg.ignoresSafeArea()
            CTNoise().ignoresSafeArea()

            VStack(spacing: 0) {
                CTNavBar(title: "PROFILE", showBack: true)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Avatar block
                        VStack(spacing: 10) {
                            CTHexAvatar(initials: "AX", size: .xlarge)
                            Text("[change photo]")
                                .font(CTFont.bold(12))
                                .foregroundColor(Color.CT.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)

                        CTSep(style: .thick)

                        CTSettingsSectionHeader(title: "IDENTITY")
                        CTSettingsRow(label: "username",      value: "<@axiom>")
                        CTSep()
                        CTSettingsRow(label: "display name",  value: "Axiom  \(CTSymbol.forward)", isAction: true)
                        CTSep()
                        CTSettingsRow(label: "status",        value: "\(CTSymbol.online)  \(CTSymbol.forward)", isAction: true)
                        CTSep()
                        CTSettingsRow(label: "bio",           value: "[add \(CTSymbol.forward)]", isAction: true)
                        CTSep()

                        CTSettingsSectionHeader(title: "ACCOUNT")
                        CTSettingsRow(label: "joined",        value: "2025/03/01")
                        CTSep()
                        CTSettingsRow(label: "user ID",       value: "4a6cff42...c4")
                        CTSep()
                        CTSettingsRow(label: "linked devices",value: "1  [manage \(CTSymbol.forward)]", isAction: true)
                        CTSep(style: .thick)

                        CTSettingsSectionHeader(title: "DANGER ZONE")
                        CTSettingsRow(label: "delete account",value: "[delete →]", isDestructive: true)
                        CTSep(style: .thick)

                        CTSystemMessage(text: "changes are end-to-end encrypted")
                            .padding(.bottom, 20)
                    }
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Chat") {
    ChatScreenPreview().preferredColorScheme(.dark)
}

#Preview("Chats List") {
    ChatsListPreview().preferredColorScheme(.dark)
}

#Preview("Settings") {
    SettingsMainPreview().preferredColorScheme(.dark)
}

#Preview("Settings › Profile") {
    ProfileDetailPreview().preferredColorScheme(.dark)
}

#Preview("Settings › Security") {
    SecurityDetailPreview().preferredColorScheme(.dark)
}

#Preview("Settings › Network") {
    NetworkDetailPreview().preferredColorScheme(.dark)
}
