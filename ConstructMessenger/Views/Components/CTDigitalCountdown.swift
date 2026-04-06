//
//  CTDigitalCountdown.swift
//  ConstructMessenger
//
//  Retro seven-segment digital display for countdowns.
//

import SwiftUI

// MARK: - Seven-segment digit

/// Bitmask of which segments are ON for each digit 0-9.
/// Segments: a(top) b(top-right) c(bot-right) d(bot) e(bot-left) f(top-left) g(middle)
private let segmentMap: [Int: [Bool]] = [
    //        a      b      c      d      e      f      g
    0: [true,  true,  true,  true,  true,  true,  false],
    1: [false, true,  true,  false, false, false, false],
    2: [true,  true,  false, true,  true,  false, true ],
    3: [true,  true,  true,  true,  false, false, true ],
    4: [false, true,  true,  false, false, true,  true ],
    5: [true,  false, true,  true,  false, true,  true ],
    6: [true,  false, true,  true,  true,  true,  true ],
    7: [true,  true,  true,  false, false, false, false],
    8: [true,  true,  true,  true,  true,  true,  true ],
    9: [true,  true,  true,  true,  false, true,  true ],
]

private struct SegmentDigit: View {
    let digit: Int          // 0-9
    let width: CGFloat
    let height: CGFloat
    let onColor: Color
    let offColor: Color
    let thickness: CGFloat

    private var segs: [Bool] { segmentMap[digit] ?? Array(repeating: false, count: 7) }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let t = thickness
            let gap: CGFloat = 2

            func hSeg(y: CGFloat, on: Bool) {
                let color = on ? onColor : offColor
                let path = Path { p in
                    let x0 = t + gap
                    let x1 = w - t - gap
                    p.move(to: CGPoint(x: x0, y: y))
                    p.addLine(to: CGPoint(x: x1, y: y))
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: t, lineCap: .square))
            }

            func vSeg(x: CGFloat, y0: CGFloat, y1: CGFloat, on: Bool) {
                let color = on ? onColor : offColor
                let path = Path { p in
                    let yy0 = y0 + gap
                    let yy1 = y1 - gap
                    p.move(to: CGPoint(x: x, y: yy0))
                    p.addLine(to: CGPoint(x: x, y: yy1))
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: t, lineCap: .square))
            }

            // a — top horizontal
            hSeg(y: t / 2, on: segs[0])
            // d — bottom horizontal
            hSeg(y: h - t / 2, on: segs[3])
            // g — middle horizontal
            hSeg(y: h / 2, on: segs[6])

            // b — top-right vertical
            vSeg(x: w - t / 2, y0: t, y1: h / 2, on: segs[1])
            // c — bottom-right vertical
            vSeg(x: w - t / 2, y0: h / 2, y1: h - t, on: segs[2])
            // f — top-left vertical
            vSeg(x: t / 2, y0: t, y1: h / 2, on: segs[5])
            // e — bottom-left vertical
            vSeg(x: t / 2, y0: h / 2, y1: h - t, on: segs[4])
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Public countdown view

struct CTDigitalCountdown: View {
    let value: Int

    private let digitW: CGFloat = 32
    private let digitH: CGFloat = 52
    private let thickness: CGFloat = 4
    private let onColor = Color.CT.danger
    private let offColor = Color.CT.danger.opacity(0.08)

    var body: some View {
        ZStack {
            // Bezel
            Rectangle()
                .fill(Color.CT.bgMsg)
                .overlay(
                    Rectangle()
                        .strokeBorder(Color.CT.danger.opacity(0.25), lineWidth: 1)
                )

            HStack(spacing: 10) {
                // Tens digit (0 when value < 10)
                SegmentDigit(
                    digit: value / 10,
                    width: digitW, height: digitH,
                    onColor: onColor, offColor: offColor,
                    thickness: thickness
                )
                // Units digit
                SegmentDigit(
                    digit: value % 10,
                    width: digitW, height: digitH,
                    onColor: onColor, offColor: offColor,
                    thickness: thickness
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .fixedSize()
        .animation(.none, value: value)
    }
}

#Preview {
    VStack(spacing: 20) {
        CTDigitalCountdown(value: 7)
        CTDigitalCountdown(value: 3)
        CTDigitalCountdown(value: 0)
    }
    .padding()
    .background(Color.CT.bg)
}
