// EVAChatPreview.swift
// Standalone design prototype — EVA / NERV aesthetic.
// NOT wired to any live data. Open in Xcode Canvas to preview.

import SwiftUI

// MARK: - Design Tokens

private enum EVA {
    static let bg         = Color(r: 10,  g: 10,  b: 11)
    static let bg2        = Color(r: 17,  g: 17,  b: 19)
    static let bg3        = Color(r: 23,  g: 23,  b: 25)
    static let accent     = Color(r: 232, g: 82,  b: 26)
    static let dim        = Color(r: 42,  g: 42,  b: 45)
    static let line       = Color(r: 30,  g: 30,  b: 34)
    static let text       = Color(r: 200, g: 196, b: 184)
    static let textDim    = Color(r: 90,  g: 88,  b: 85)
    static let textBright = Color(r: 232, g: 228, b: 216)
    static let green      = Color(r: 61,  g: 138, b: 74)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    // Futura is bundled with iOS and gives a geometric/military character
    // close to Rajdhani. Falls back gracefully.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        Font.custom("Futura-Medium", size: size).weight(weight)
    }
}

private extension Color {
    init(r: Double, g: Double, b: Double) {
        self.init(red: r / 255, green: g / 255, blue: b / 255)
    }
}

// MARK: - Private Shapes (prefixed to avoid collisions with production shapes)

private struct _EVAHex: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let r  = min(rect.width, rect.height) / 2
        var p  = Path()
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 - .pi / 6
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath(); return p
    }
}

private struct _EVAOut: Shape {   // outgoing bubble: top-right clipped
    var cut: CGFloat = 10
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath(); return p
    }
}

private struct _EVAIn: Shape {    // incoming bubble: top-left clipped
    var cut: CGFloat = 10
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        p.closeSubpath(); return p
    }
}

// MARK: - Grid Background

private struct EVAGrid: View {
    var spacing: CGFloat = 40
    var body: some View {
        Canvas { ctx, size in
            ctx.opacity = 0.07
            var x: CGFloat = 0
            while x <= size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(EVA.dim), lineWidth: 0.5)
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(EVA.dim), lineWidth: 0.5)
                y += spacing
            }
        }
    }
}

// MARK: - Hex Avatar

struct EVAHexAvatar: View {
    let initials: String
    let color: Color
    var size: CGFloat = 36
    var isActive: Bool = false

    var body: some View {
        ZStack {
            _EVAHex().fill(EVA.bg3)
            _EVAHex().stroke(color.opacity(isActive ? 1 : 0.7), lineWidth: 1.5)
            Text(initials)
                .font(EVA.mono(size * 0.28, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(isActive ? 0.5 : 0.2), radius: isActive ? 4 : 1)
    }
}

// MARK: - Topbar

private struct EVATopbar: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CONSTRUCT")
                    .font(EVA.mono(12, weight: .bold))
                    .foregroundStyle(EVA.accent)
                    .kerning(3)

                Spacer()

                Text("SECURE·MESH")
                    .font(EVA.mono(9))
                    .foregroundStyle(EVA.textDim)
                    .kerning(1.5)

                Spacer()

                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Circle().fill(EVA.green).frame(width: 5, height: 5)
                        Text("CONNECTED")
                            .font(EVA.mono(8))
                            .foregroundStyle(EVA.green)
                    }
                    Text("PQC·KYBER-768")
                        .font(EVA.mono(8))
                        .foregroundStyle(EVA.accent)
                        .kerning(0.5)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(EVA.bg2)

            LinearGradient(
                colors: [EVA.accent.opacity(0.8), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)
        }
    }
}

// MARK: - Chat Header

private struct EVAChatHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                EVAHexAvatar(
                    initials: "KM",
                    color: Color(hue: 0.55, saturation: 0.6, brightness: 0.7),
                    size: 34,
                    isActive: true
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("KIM YONSEI")
                        .font(EVA.display(13))
                        .foregroundStyle(EVA.textBright)
                        .kerning(1)
                    HStack(spacing: 4) {
                        Circle().fill(EVA.green).frame(width: 4, height: 4)
                        Text("ONLINE  ·  RTT 38ms")
                            .font(EVA.mono(8))
                            .foregroundStyle(EVA.green)
                            .kerning(0.5)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Circle().fill(EVA.green).frame(width: 4, height: 4)
                        Text("X25519+KYBER · CHACHA20")
                            .font(EVA.mono(7))
                            .foregroundStyle(EVA.green)
                            .kerning(0.3)
                    }
                    Text("FP: A3F9·CC14·8B02·E71A")
                        .font(EVA.mono(7))
                        .foregroundStyle(EVA.textDim)
                        .kerning(0.5)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(EVA.bg.opacity(0.95))

            Rectangle().fill(EVA.line).frame(height: 1)
        }
    }
}

// MARK: - Message Bubble

private struct EVABubble: View {
    let text: String
    let time: String
    let isOut: Bool
    let status: String

    private var accent: Color {
        isOut ? EVA.accent : Color(hue: 0.55, saturation: 0.6, brightness: 0.7)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOut { Spacer(minLength: 44) }

            VStack(alignment: isOut ? .trailing : .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(EVA.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(bubbleBG)

                // Metadata
                HStack(spacing: 6) {
                    Text(time)
                        .font(EVA.mono(7))
                        .foregroundStyle(EVA.textDim)
                        .kerning(0.5)
                    if !status.isEmpty {
                        Text(status)
                            .font(EVA.mono(7, weight: .medium))
                            .foregroundStyle(EVA.green.opacity(0.85))
                            .kerning(0.5)
                    }
                }
                .padding(.horizontal, 2)
            }

            if !isOut { Spacer(minLength: 44) }
        }
    }

    @ViewBuilder
    private var bubbleBG: some View {
        if isOut {
            ZStack {
                _EVAOut().fill(EVA.accent.opacity(0.08))
                _EVAOut().stroke(EVA.accent.opacity(0.35), lineWidth: 1)
            }
        } else {
            ZStack {
                _EVAIn().fill(EVA.bg3)
                _EVAIn().stroke(EVA.dim, lineWidth: 1)
                // left accent stripe
                HStack {
                    Rectangle()
                        .fill(accent.opacity(0.55))
                        .frame(width: 2)
                    Spacer()
                }
            }
        }
    }
}

// MARK: - System Message

private struct EVASysMsg: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(EVA.dim).frame(height: 1)
            Text(text)
                .font(EVA.mono(7))
                .foregroundStyle(EVA.textDim)
                .kerning(1.5)
                .fixedSize()
            Rectangle().fill(EVA.dim).frame(height: 1)
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Input Bar

private struct EVAInputBar: View {
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.clear, EVA.accent.opacity(0.35), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 1)

            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text("ENTER MESSAGE")
                            .font(EVA.mono(11))
                            .foregroundStyle(EVA.textDim)
                            .kerning(0.5)
                            .padding(.horizontal, 10)
                    }
                    TextField("", text: $draft)
                        .font(.system(size: 13))
                        .foregroundStyle(EVA.text)
                        .focused($focused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                }
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 2).fill(EVA.bg3)
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(focused ? EVA.accent.opacity(0.5) : EVA.dim, lineWidth: 1)
                    }
                )

                // SEND — clipped corner button
                Button(action: {}) {
                    Text("SEND")
                        .font(EVA.mono(11, weight: .bold))
                        .foregroundStyle(EVA.textBright)
                        .kerning(1.5)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            ZStack {
                                _EVAOut(cut: 7).fill(EVA.accent)
                            }
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(EVA.bg2)
        }
    }
}

// MARK: - Full Chat Preview

struct EVAChatPreview: View {
    private struct Msg {
        let text: String; let time: String; let out: Bool; let status: String
        var isSystem: Bool { status.isEmpty && !out && text.hasPrefix("SESSION") }
    }
    private let msgs: [Msg] = [
        Msg(text: "SESSION ESTABLISHED", time: "", out: false, status: ""),
        Msg(text: "Hey. Secure channel up?",               time: "10:14:07", out: false, status: "E2E·OK"),
        Msg(text: "Yeah. KYBER handshake done, PFS active.", time: "10:14:23", out: true,  status: "SENT·E2E"),
        Msg(text: "Good. Sending the keys over now.",       time: "10:14:31", out: false, status: "E2E·OK"),
        Msg(text: "Received. Verifying fingerprint.",       time: "10:14:44", out: true,  status: "SENT·E2E"),
        Msg(text: "FP matches on my side: A3F9·CC14·8B02", time: "10:14:58", out: false, status: "E2E·OK"),
        Msg(text: "Confirmed. We're good.",                 time: "10:15:03", out: true,  status: "DELIVERED·E2E"),
    ]

    var body: some View {
        ZStack {
            EVA.bg.ignoresSafeArea()
            EVAGrid().ignoresSafeArea()

            VStack(spacing: 0) {
                EVATopbar()
                EVAChatHeader()

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in
                            if m.isSystem {
                                EVASysMsg(text: "SESSION·ESTABLISHED · KEY·EXCHANGE·COMPLETE · FORWARD·SECRECY·ACTIVE")
                                    .padding(.vertical, 4)
                            } else {
                                EVABubble(text: m.text, time: m.time, isOut: m.out, status: m.status)
                                    .padding(.horizontal, 12)
                            }
                        }
                    }
                    .padding(.vertical, 14)
                }
                .background(EVA.bg)

                EVAInputBar()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Contacts List Preview

struct EVAContactsPreview: View {
    private struct Contact {
        let name: String; let preview: String; let time: String
        let unread: Int; let hue: Double; let online: Bool
    }
    private let contacts: [Contact] = [
        Contact(name: "KIM YONSEI",  preview: "FP matches on my side: A3F9·CC14",       time: "10:15", unread: 0, hue: 0.55, online: true),
        Contact(name: "ALEX MORROW", preview: "Session re-keyed automatically",           time: "09:42", unread: 2, hue: 0.12, online: true),
        Contact(name: "PRIYA CHEN",  preview: "Kyber OTP consumed, new bundle uploaded", time: "YST",   unread: 0, hue: 0.72, online: false),
        Contact(name: "UNIT-04",     preview: "KEY_SYNC request received",                time: "YST",   unread: 1, hue: 0.33, online: false),
    ]

    var body: some View {
        ZStack {
            EVA.bg2.ignoresSafeArea()
            EVAGrid().ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("CHANNELS")
                        .font(EVA.mono(10, weight: .medium))
                        .foregroundStyle(EVA.textDim)
                        .kerning(2)
                    Text("\(contacts.count)")
                        .font(EVA.mono(9))
                        .foregroundStyle(EVA.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(EVA.accent.opacity(0.15))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                Rectangle().fill(EVA.line).frame(height: 1)

                ForEach(Array(contacts.enumerated()), id: \.offset) { i, c in
                    contactRow(c, active: i == 0)
                    Rectangle().fill(EVA.line).frame(height: 1)
                }

                Spacer()

                Rectangle().fill(EVA.line).frame(height: 1)
                HStack(spacing: 10) {
                    EVAHexAvatar(initials: "ML", color: EVA.accent, size: 34, isActive: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MAXIM LISEYEV")
                            .font(EVA.display(12))
                            .foregroundStyle(EVA.textBright)
                            .kerning(0.5)
                        Text("@maxim · ONLINE")
                            .font(EVA.mono(8))
                            .foregroundStyle(EVA.textDim)
                    }
                    Spacer()
                    Circle().fill(EVA.green).frame(width: 6, height: 6)
                        .shadow(color: EVA.green.opacity(0.8), radius: 3)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(EVA.bg3)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func contactRow(_ c: Contact, active: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(active ? EVA.accent : .clear)
                .frame(width: 2)

            HStack(spacing: 10) {
                EVAHexAvatar(
                    initials: String(c.name.prefix(2)),
                    color: Color(hue: c.hue, saturation: 0.6, brightness: 0.7),
                    size: 34,
                    isActive: c.online
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(c.name)
                            .font(EVA.display(12))
                            .foregroundStyle(active ? EVA.textBright : EVA.text)
                            .kerning(0.5)
                        Spacer()
                        Text(c.time)
                            .font(EVA.mono(8))
                            .foregroundStyle(EVA.textDim)
                    }
                    HStack {
                        Text(c.preview)
                            .font(EVA.mono(8))
                            .foregroundStyle(EVA.textDim)
                            .lineLimit(1)
                            .kerning(0.2)
                        Spacer()
                        if c.unread > 0 {
                            Text("\(c.unread)")
                                .font(EVA.mono(8, weight: .bold))
                                .foregroundStyle(EVA.bg)
                                .frame(width: 16, height: 16)
                                .background(EVA.accent)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(active ? EVA.accent.opacity(0.06) : .clear)
        }
    }
}

// MARK: - Previews

#Preview("Chat · iPhone 16") {
    EVAChatPreview()
        .frame(width: 393, height: 852)
}

#Preview("Contacts sidebar") {
    EVAContactsPreview()
        .frame(width: 280, height: 620)
}

#Preview("Components") {
    ZStack {
        EVA.bg.ignoresSafeArea()
        ScrollView {
            VStack(spacing: 24) {
                // Avatars
                HStack(spacing: 16) {
                    EVAHexAvatar(initials: "KM", color: Color(hue: 0.55, saturation: 0.6, brightness: 0.7), size: 48, isActive: true)
                    EVAHexAvatar(initials: "ML", color: EVA.accent, size: 48, isActive: true)
                    EVAHexAvatar(initials: "AP", color: Color(hue: 0.72, saturation: 0.6, brightness: 0.7), size: 48)
                    EVAHexAvatar(initials: "U4", color: Color(hue: 0.33, saturation: 0.6, brightness: 0.7), size: 48)
                }

                EVASysMsg(text: "SESSION·ESTABLISHED · FORWARD·SECRECY·ACTIVE")
                    .frame(maxWidth: .infinity)

                EVABubble(text: "Secure channel established.", time: "10:14:07", isOut: false, status: "E2E·OK")
                    .padding(.horizontal, 12)
                EVABubble(text: "Confirmed. Keys verified.", time: "10:14:23", isOut: true, status: "SENT·E2E")
                    .padding(.horizontal, 12)
                EVABubble(text: "FP: A3F9·CC14·8B02·E71A — all clear.", time: "10:15:03", isOut: false, status: "E2E·OK")
                    .padding(.horizontal, 12)
            }
            .padding(.vertical, 20)
        }
    }
    .preferredColorScheme(.dark)
    .frame(width: 393)
}
