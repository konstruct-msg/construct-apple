// ConstructChatPreview.swift
// Standalone design prototype — Construct terminal aesthetic.
// NOT wired to any live data. Open in Xcode Canvas to preview.
// Ref: /Users/maximeliseyev/Documents/Konstruct/ASCII_style_design.md

import SwiftUI

// MARK: - Design Tokens

private enum CT {
    // Colors — inline to avoid collision with global Color.init(hex:)
    static let bg          = Color(r: 9,   g: 9,   b: 9)
    static let bgMsgIn     = Color(r: 17,  g: 17,  b: 17)
    static let bgMsgOut    = Color(r: 26,  g: 63,  b: 255)
    static let accent      = Color(r: 26,  g: 63,  b: 255)
    static let accentDim   = Color(r: 74,  g: 106, b: 255)
    static let text        = Color(r: 232, g: 232, b: 232)
    static let textDim     = Color(r: 85,  g: 85,  b: 85)
    static let noiseColor  = Color(r: 30,  g: 30,  b: 30)

    // Typography — JetBrains Mono everywhere
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrainsMono-Regular", size: size)
            .weight(weight)
    }
    static func monoB(_ size: CGFloat) -> Font { mono(size, weight: .bold) }
}

private extension Color {
    init(r: Double, g: Double, b: Double) {
        self.init(red: r / 255, green: g / 255, blue: b / 255)
    }
}

// MARK: - ASCII Noise Background

private let noiseChars: [Character] = [
    "@", "%", "#", "+", "-", "=", ":", ".", "*", "/", "\\", "(", ")", "|", "~", "^", "<", ">"
]

private struct ASCIINoise: View {
    // Seeded noise grid so it's stable in preview
    private let rows = 40
    private let cols = 22
    private let grid: [[Character]]

    init() {
        var rng = SeedableRNG(seed: 42)
        grid = (0..<40).map { _ in
            (0..<22).map { _ in noiseChars[rng.next() % noiseChars.count] }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let charW = geo.size.width  / CGFloat(cols)
            let charH = geo.size.height / CGFloat(rows)
            Canvas { ctx, _ in
                ctx.opacity = 0.10
                for row in 0..<rows {
                    for col in 0..<cols {
                        let ch = String(grid[row][col])
                        let x = CGFloat(col) * charW
                        let y = CGFloat(row) * charH
                        ctx.draw(
                            Text(ch).font(CT.mono(10)).foregroundColor(CT.noiseColor),
                            at: CGPoint(x: x, y: y),
                            anchor: .topLeading
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct SeedableRNG {
    var state: Int
    init(seed: Int) { state = seed }
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return abs(state) % noiseChars.count
    }
}

// MARK: - Hexagonal Avatar

private struct HexAvatar: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let r  = min(rect.width, rect.height) / 2
        var p  = Path()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 - .pi / 6
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

private struct HexAvatarView: View {
    var initials: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            HexAvatar()
                .fill(CT.accent.opacity(0.25))
            HexAvatar()
                .stroke(CT.accent, lineWidth: 1)
            Text(initials)
                .font(CT.monoB(size * 0.3))
                .foregroundColor(CT.accent)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Message Models

private struct PreviewMessage: Identifiable {
    let id = UUID()
    let text: String
    let isOutgoing: Bool
    let time: String
    let status: MessageStatus
    enum MessageStatus { case sent, delivered, read }
}

// MARK: - Highlighted Text Message Bubble
// Messages are rendered as highlighted text (coloured background block),
// NOT as chat bubbles with rounded corners.

private struct MessageRow: View {
    let msg: PreviewMessage

    var body: some View {
        if msg.isOutgoing {
            outgoing
        } else {
            incoming
        }
    }

    private var incoming: some View {
        HStack(alignment: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                // Highlighted text block — no border radius
                Text(msg.text)
                    .font(CT.mono(14))
                    .foregroundColor(CT.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(CT.bgMsgIn)
                    .clipShape(Rectangle())
                    .overlay(
                        Rectangle()
                            .stroke(CT.noiseColor, lineWidth: 0.5)
                    )
                HStack(spacing: 4) {
                    Text(msg.time)
                        .font(CT.mono(10))
                        .foregroundColor(CT.textDim)
                }
            }
            Spacer(minLength: 60)
        }
        .padding(.horizontal, 12)
    }

    private var outgoing: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 2) {
                // Highlighted text block — accent background
                Text(msg.text)
                    .font(CT.mono(14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(CT.bgMsgOut)
                    .clipShape(Rectangle())
                HStack(spacing: 4) {
                    Text(msg.time)
                        .font(CT.mono(10))
                        .foregroundColor(CT.textDim)
                    Text(statusGlyph)
                        .font(CT.mono(10))
                        .foregroundColor(msg.status == .read ? CT.accent : CT.textDim)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var statusGlyph: String {
        switch msg.status {
        case .sent:      return "[✓]"
        case .delivered: return "[✓✓]"
        case .read:      return "[↵]"
        }
    }
}

// MARK: - System Message

private struct SystemMessageView: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Text(">")
                .font(CT.monoB(12))
                .foregroundColor(CT.accentDim)
            Text(text)
                .font(CT.mono(12))
                .foregroundColor(CT.accentDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

// MARK: - Input Bar

private struct InputBar: View {
    @State private var text = ""
    @State private var cursorVisible = true

    var body: some View {
        HStack(spacing: 12) {
            // Media symbol
            Text("[◎]")
                .font(CT.mono(14))
                .foregroundColor(CT.textDim)

            // Input field with terminal cursor
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    HStack(spacing: 0) {
                        Text("type a message")
                            .font(CT.mono(14))
                            .foregroundColor(CT.textDim)
                        Text("_")
                            .font(CT.monoB(14))
                            .foregroundColor(CT.accentDim)
                            .opacity(cursorVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.5).repeatForever(), value: cursorVisible)
                            .onAppear { cursorVisible.toggle() }
                    }
                }
                TextField("", text: $text)
                    .font(CT.mono(14))
                    .foregroundColor(CT.text)
                    .tint(CT.accent)
            }
            .frame(maxWidth: .infinity)

            // Send symbol
            Text("[→]")
                .font(CT.monoB(14))
                .foregroundColor(CT.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack(alignment: .top) {
                CT.bg
                Rectangle().frame(height: 0.5).foregroundColor(CT.noiseColor)
            }
        )
    }
}

// MARK: - Navigation Bar

private struct ChatNavBar: View {
    var body: some View {
        HStack(spacing: 10) {
            // Back
            Text("[←]")
                .font(CT.monoB(14))
                .foregroundColor(CT.accent)

            HexAvatarView(initials: "AX", size: 32)

            // Username in angle brackets
            Text("<@axiom>")
                .font(CT.monoB(14))
                .foregroundColor(CT.text)

            Spacer()

            // Online indicator
            Text("[[ONLINE]]")
                .font(CT.mono(11))
                .foregroundColor(CT.accentDim)

            // Menu
            Text("[***]")
                .font(CT.monoB(14))
                .foregroundColor(CT.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack(alignment: .bottom) {
                CT.bg
                Rectangle().frame(height: 0.5).foregroundColor(CT.noiseColor)
            }
        )
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
                HexAvatarView(initials: String(username.prefix(2).uppercased()), size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("<@\(username)>")
                            .font(CT.monoB(14))
                            .foregroundColor(CT.text)
                        Spacer()
                        Text(time)
                            .font(CT.mono(11))
                            .foregroundColor(CT.textDim)
                    }
                    HStack {
                        Text(preview)
                            .font(CT.mono(12))
                            .foregroundColor(CT.textDim)
                            .lineLimit(1)
                        Spacer()
                        if unread > 0 {
                            Text("[\(unread)]")
                                .font(CT.monoB(11))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(CT.accent)
                                .clipShape(Rectangle())
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Dashed separator
            Text(String(repeating: "- ", count: 25))
                .font(CT.mono(10))
                .foregroundColor(CT.noiseColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
        }
    }
}

// MARK: - Chat Screen Preview

private struct ChatScreenPreview: View {
    private let messages: [PreviewMessage] = [
        .init(text: "CONNECTION SECURED\nPROTOCOL: PQXDH + DR", isOutgoing: false, time: "10:28", status: .read),
        .init(text: "What time is the event today at\nthe office?", isOutgoing: false, time: "10:30", status: .read),
        .init(text: "It starts at 7pm but if you're\navailable can you come in early\nto help set up?", isOutgoing: true, time: "10:34", status: .read),
        .init(text: "Sure, I can be there by 5pm.\nShould I bring anything?", isOutgoing: false, time: "10:36", status: .read),
        .init(text: "Just yourself 👍", isOutgoing: true, time: "10:37", status: .delivered),
        .init(text: "On my way", isOutgoing: false, time: "10:52", status: .read),
    ]

    var body: some View {
        ZStack {
            CT.bg.ignoresSafeArea()
            ASCIINoise().ignoresSafeArea()

            VStack(spacing: 0) {
                ChatNavBar()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Single-line session status
                        SystemMessageView(text: "E2EE SESSION ACTIVE · RATCHET IN SYNC")

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

// MARK: - Chats List Screen Preview

private struct ChatsListPreview: View {
    private let chats = [
        (user: "axiom",    preview: "On my way",              time: "10:52", unread: 0),
        (user: "phantom",  preview: "Did you see the report?", time: "09:14", unread: 3),
        (user: "neo_rx",   preview: "Keys verified ✓",         time: "Вчера", unread: 0),
        (user: "construct",preview: "System message",          time: "Пн",    unread: 1),
    ]

    var body: some View {
        ZStack {
            CT.bg.ignoresSafeArea()
            ASCIINoise().ignoresSafeArea()

            VStack(spacing: 0) {
                // Status header — connection info instead of app title
                VStack(alignment: .leading, spacing: 1) {
                    SystemMessageView(text: "RELAY: ams.konstruct.cc · TLS+OBFS4")
                    SystemMessageView(text: "SESSION STREAM ACTIVE · [+]")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background(
                    ZStack(alignment: .bottom) {
                        CT.bg
                        Rectangle().frame(height: 0.5).foregroundColor(CT.noiseColor)
                    }
                )

                // Search bar
                HStack {
                    Text("[")
                        .font(CT.mono(14))
                        .foregroundColor(CT.textDim)
                    Text("search_")
                        .font(CT.mono(14))
                        .foregroundColor(CT.textDim)
                    Spacer()
                    Text("]")
                        .font(CT.mono(14))
                        .foregroundColor(CT.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CT.bgMsgIn)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(chats, id: \.user) { chat in
                            ChatListRow(
                                username: chat.user,
                                preview: chat.preview,
                                time: chat.time,
                                unread: chat.unread
                            )
                        }
                    }
                }

                // Tab bar
                HStack {
                    Spacer()
                    Text("[⌂]")
                        .font(CT.monoB(16))
                        .foregroundColor(CT.accent)
                    Spacer()
                    Text("[⊹]")
                        .font(CT.mono(16))
                        .foregroundColor(CT.textDim)
                    Spacer()
                    Text("[cfg]")
                        .font(CT.mono(16))
                        .foregroundColor(CT.textDim)
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(
                    ZStack(alignment: .top) {
                        CT.bg
                        Rectangle().frame(height: 0.5).foregroundColor(CT.noiseColor)
                    }
                )
            }
        }
    }
}

// MARK: - Settings Row

private struct SettingsRow: View {
    let label: String
    let value: String
    var valueColor: Color = CT.text
    var isAction: Bool = false
    var isDestructive: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(CT.mono(13))
                .foregroundColor(isDestructive ? Color(r: 220, g: 60, b: 60) : CT.textDim)
                .frame(width: 140, alignment: .leading)

            Spacer(minLength: 8)

            Text(value)
                .font(isAction ? CT.monoB(13) : CT.mono(13))
                .foregroundColor(
                    isDestructive ? Color(r: 220, g: 60, b: 60)
                    : isAction ? CT.accent
                    : valueColor
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Text(String(repeating: "- ", count: 25))
            .font(CT.mono(10))
            .foregroundColor(CT.noiseColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
}

private struct SettingsSection: View {
    let title: String
    let rows: [AnyView]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 6) {
                Text(">")
                    .font(CT.monoB(11))
                    .foregroundColor(CT.accentDim)
                Text(title)
                    .font(CT.monoB(11))
                    .foregroundColor(CT.accentDim)
            }
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 4)

            ForEach(rows.indices, id: \.self) { i in
                rows[i]
                if i < rows.count - 1 {
                    SettingsDivider()
                }
            }
        }
    }
}

// MARK: - Nav helpers

private struct DetailNavBar: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text("[←]")
                .font(CT.monoB(14))
                .foregroundColor(CT.accent)
            Text(title)
                .font(CT.monoB(15))
                .foregroundColor(CT.text)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            ZStack(alignment: .bottom) {
                CT.bg
                Rectangle().frame(height: 0.5).foregroundColor(CT.noiseColor)
            }
        )
    }
}

private struct SectionSep: View {
    var double: Bool = false
    var body: some View {
        Text(String(repeating: double ? "= " : "- ", count: 25))
            .font(CT.mono(10))
            .foregroundColor(CT.noiseColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
}

// MARK: - Detail: Profile

private struct ProfileDetailPreview: View {
    var body: some View {
        ZStack {
            CT.bg.ignoresSafeArea()
            ASCIINoise().ignoresSafeArea()
            VStack(spacing: 0) {
                DetailNavBar(title: "PROFILE")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Avatar block
                        VStack(spacing: 10) {
                            HexAvatarView(initials: "AX", size: 72)
                            Text("[change photo]")
                                .font(CT.monoB(12))
                                .foregroundColor(CT.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)

                        SectionSep(double: true)

                        // Editable fields
                        SettingsSection(title: "IDENTITY", rows: [
                            AnyView(SettingsRow(label: "username",   value: "<@axiom>")),
                            AnyView(SettingsRow(label: "display name", value: "Axiom  [edit →]", isAction: true)),
                            AnyView(SettingsRow(label: "status",     value: "[[ONLINE]]  [edit →]", isAction: true)),
                            AnyView(SettingsRow(label: "bio",        value: "[add →]", isAction: true)),
                        ])

                        SectionSep()

                        SettingsSection(title: "ACCOUNT", rows: [
                            AnyView(SettingsRow(label: "joined",     value: "2025/03/01")),
                            AnyView(SettingsRow(label: "user ID",    value: "4a6cff42...c4")),
                            AnyView(SettingsRow(label: "linked devices", value: "1  [manage →]", isAction: true)),
                        ])

                        SectionSep(double: true)

                        SettingsSection(title: "DANGER ZONE", rows: [
                            AnyView(SettingsRow(label: "delete account", value: "[delete →]", isDestructive: true)),
                        ])

                        SectionSep(double: true)
                        Text("> changes are end-to-end encrypted")
                            .font(CT.mono(11))
                            .foregroundColor(CT.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

// MARK: - Detail: Security / Keys

private struct SecurityDetailPreview: View {
    var body: some View {
        ZStack {
            CT.bg.ignoresSafeArea()
            ASCIINoise().ignoresSafeArea()
            VStack(spacing: 0) {
                DetailNavBar(title: "SECURITY")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        SettingsSection(title: "IDENTITY KEYS", rows: [
                            AnyView(SettingsRow(label: "IK algorithm",   value: "ED25519")),
                            AnyView(SettingsRow(label: "PQ algorithm",   value: "Kyber-1024")),
                            AnyView(SettingsRow(label: "key status",     value: "[✓] VERIFIED", valueColor: CT.accentDim)),
                            AnyView(SettingsRow(label: "fingerprint",    value: "[show QR →]", isAction: true)),
                        ])

                        SectionSep()

                        // Fingerprint block
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(">")
                                    .font(CT.monoB(11))
                                    .foregroundColor(CT.accentDim)
                                Text("KEY FINGERPRINT")
                                    .font(CT.monoB(11))
                                    .foregroundColor(CT.accentDim)
                            }
                            .padding(.top, 16)

                            VStack(alignment: .leading, spacing: 2) {
                                ForEach([
                                    "3A:F2:11:9C:4B:E0:72:DA",
                                    "8F:C3:55:1A:B7:29:6E:04",
                                    "D1:40:88:3C:F9:71:2B:5A",
                                    "E6:0D:44:97:CB:16:73:8F",
                                ], id: \.self) { chunk in
                                    Text(chunk)
                                        .font(CT.monoB(13))
                                        .foregroundColor(CT.accentDim)
                                }
                            }
                            .padding(10)
                            .background(CT.bgMsgIn)
                            .overlay(Rectangle().stroke(CT.noiseColor, lineWidth: 0.5))
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)

                        SectionSep()

                        SettingsSection(title: "DOUBLE RATCHET", rows: [
                            AnyView(SettingsRow(label: "active sessions", value: "12")),
                            AnyView(SettingsRow(label: "SPK rotation",    value: "every 14d")),
                            AnyView(SettingsRow(label: "next rotation",   value: "in 3 days")),
                            AnyView(SettingsRow(label: "OTPK pool",       value: "48 / 100")),
                            AnyView(SettingsRow(label: "session list",    value: "[view →]", isAction: true)),
                        ])

                        SectionSep()

                        SettingsSection(title: "ACTIONS", rows: [
                            AnyView(SettingsRow(label: "rotate SPK now",  value: "[run →]",    isAction: true)),
                            AnyView(SettingsRow(label: "clear all sessions", value: "[clear →]", isDestructive: true)),
                        ])

                        SectionSep(double: true)
                        Text("> PQXDH + Double Ratchet · post-quantum forward secrecy")
                            .font(CT.mono(11))
                            .foregroundColor(CT.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

// MARK: - Detail: Network

private struct NetworkDetailPreview: View {
    var body: some View {
        ZStack {
            CT.bg.ignoresSafeArea()
            ASCIINoise().ignoresSafeArea()
            VStack(spacing: 0) {
                DetailNavBar(title: "NETWORK")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        SettingsSection(title: "ACTIVE RELAY", rows: [
                            AnyView(SettingsRow(label: "host",        value: "ams.konstruct.cc")),
                            AnyView(SettingsRow(label: "port",        value: "443")),
                            AnyView(SettingsRow(label: "transport",   value: "TLS + OBFS4",  valueColor: CT.accentDim)),
                            AnyView(SettingsRow(label: "protocol",    value: "gRPC / binary", valueColor: CT.accentDim)),
                            AnyView(SettingsRow(label: "latency",     value: "~38ms")),
                            AnyView(SettingsRow(label: "status",      value: "[[CONNECTED]]", valueColor: CT.accentDim)),
                        ])

                        SectionSep()

                        SettingsSection(title: "FALLBACK RELAY", rows: [
                            AnyView(SettingsRow(label: "host",        value: "msk.konstruct.cc")),
                            AnyView(SettingsRow(label: "port",        value: "443")),
                            AnyView(SettingsRow(label: "transport",   value: "TLS + OBFS4")),
                            AnyView(SettingsRow(label: "status",      value: "standby")),
                        ])

                        SectionSep()

                        SettingsSection(title: "BEHAVIOUR", rows: [
                            AnyView(SettingsRow(label: "bg grace",    value: "5s")),
                            AnyView(SettingsRow(label: "auto-reconnect", value: "[ON]",  valueColor: CT.accentDim)),
                            AnyView(SettingsRow(label: "cert pinning",value: "[ON]",  valueColor: CT.accentDim)),
                        ])

                        SectionSep(double: true)
                        Text("> all traffic obfuscated · no metadata leakage")
                            .font(CT.mono(11))
                            .foregroundColor(CT.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }
}

// MARK: - Main Settings Screen

private struct SettingsPreview: View {
    var body: some View {
        ZStack {
            CT.bg.ignoresSafeArea()
            ASCIINoise().ignoresSafeArea()

            VStack(spacing: 0) {
                // Nav bar
                HStack(spacing: 10) {
                    Text("[cfg]")
                        .font(CT.monoB(14))
                        .foregroundColor(CT.accent)
                    Text("SETTINGS")
                        .font(CT.monoB(15))
                        .foregroundColor(CT.text)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    ZStack(alignment: .bottom) {
                        CT.bg
                        Rectangle().frame(height: 0.5).foregroundColor(CT.noiseColor)
                    }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // ── PROFILE (drill-down) ──────────────────────────
                        HStack(spacing: 14) {
                            HexAvatarView(initials: "AX", size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("<@axiom>")
                                    .font(CT.monoB(15))
                                    .foregroundColor(CT.text)
                                Text("[[ONLINE]] · keys [✓]")
                                    .font(CT.mono(11))
                                    .foregroundColor(CT.accentDim)
                            }
                            Spacer()
                            Text("[→]")
                                .font(CT.monoB(16))
                                .foregroundColor(CT.accent)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)

                        SectionSep(double: true)

                        // ── SECURITY (drill-down) ─────────────────────────
                        SettingsSection(title: "SECURITY", rows: [
                            AnyView(SettingsRow(label: "keys & sessions", value: "[→]", isAction: true)),
                        ])

                        SectionSep()

                        // ── NETWORK (drill-down) ──────────────────────────
                        SettingsSection(title: "NETWORK", rows: [
                            AnyView(SettingsRow(label: "relay / transport", value: "[→]", isAction: true)),
                        ])

                        SectionSep()

                        // ── NOTIFICATIONS (inline toggles) ────────────────
                        SettingsSection(title: "NOTIFICATIONS", rows: [
                            AnyView(SettingsRow(label: "push alerts",    value: "[ON]",  valueColor: CT.accentDim)),
                            AnyView(SettingsRow(label: "voip calls",     value: "[ON]",  valueColor: CT.accentDim)),
                            AnyView(SettingsRow(label: "message preview",value: "[OFF]", valueColor: CT.textDim)),
                            AnyView(SettingsRow(label: "sounds",         value: "[ON]",  valueColor: CT.accentDim)),
                        ])

                        SectionSep()

                        // ── APPEARANCE (inline) ───────────────────────────
                        SettingsSection(title: "APPEARANCE", rows: [
                            AnyView(SettingsRow(label: "theme",     value: "DARK [●]", valueColor: CT.accentDim)),
                            AnyView(SettingsRow(label: "font size", value: "14px")),
                            AnyView(SettingsRow(label: "noise",     value: "10% opacity")),
                        ])

                        SectionSep()

                        // ── DANGER (inline actions) ───────────────────────
                        SettingsSection(title: "DANGER ZONE", rows: [
                            AnyView(SettingsRow(label: "clear sessions", value: "[run →]",    isAction: true)),
                            AnyView(SettingsRow(label: "delete account", value: "[delete →]", isDestructive: true)),
                        ])

                        SectionSep(double: true)

                        Text("> construct-messenger v0.9 · core v0.6")
                            .font(CT.mono(11))
                            .foregroundColor(CT.textDim)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 20)
                            .padding(.top, 6)
                    }
                }

                // Tab bar
                HStack {
                    Spacer()
                    Text("[⌂]").font(CT.mono(16)).foregroundColor(CT.textDim)
                    Spacer()
                    Text("[⊹]").font(CT.mono(16)).foregroundColor(CT.textDim)
                    Spacer()
                    Text("[cfg]").font(CT.monoB(16)).foregroundColor(CT.accent)
                    Spacer()
                }
                .padding(.vertical, 12)
                .background(
                    ZStack(alignment: .top) {
                        CT.bg
                        Rectangle().frame(height: 0.5).foregroundColor(CT.noiseColor)
                    }
                )
            }
        }
    }
}

#Preview("Chat") {
    ChatScreenPreview()
        .preferredColorScheme(.dark)
}

#Preview("Chats List") {
    ChatsListPreview()
        .preferredColorScheme(.dark)
}

#Preview("Settings") {
    SettingsPreview()
        .preferredColorScheme(.dark)
}

#Preview("Settings › Profile") {
    ProfileDetailPreview()
        .preferredColorScheme(.dark)
}

#Preview("Settings › Security") {
    SecurityDetailPreview()
        .preferredColorScheme(.dark)
}

#Preview("Settings › Network") {
    NetworkDetailPreview()
        .preferredColorScheme(.dark)
}
