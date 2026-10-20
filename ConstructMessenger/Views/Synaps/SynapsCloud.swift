//
//  SynapsCloud.swift
//  Construct Messenger
//
//  The contact cloud and its ContactCircle, split out of SynapsView.swift.
//


import SwiftUI
import CoreData
#if os(iOS)
import UIKit
#endif

// MARK: - Cloud

struct SynapsCloud: View {
    let layout:       SynapsCloudLayout
    let metricsByUser: [String: ContactMetrics]
    @Binding var selected: ContactRecord?
    let canvasScale:  CGFloat
    let canvasOffset: CGSize
    /// The middle of the visible part of the canvas; the cloud's centre and the lens sit here.
    let focus:        CGPoint
    let lens:         SynapsLens

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(layout.items) { item in
                let placed = place(item)
                ContactCircle(
                    user:         item.user,
                    pitch:        SynapsCloudLayout.pitch,
                    metrics:      metricsByUser[item.user.id] ?? .zero,
                    lensScale:    placed.scale,
                    lensOpacity:  placed.opacity,
                    labelOpacity: placed.labelOpacity
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                        selected = item.user
                    }
                }
                .position(placed.position)
            }
        }
    }

    /// Where the lens draws a contact. ZoomableCloud scales the canvas about `focus` and then
    /// pans it, so the contact's screen point is worked out, moved by the lens, and taken back
    /// to the canvas point that lands there.
    private func place(_ item: SynapsCloudLayout.Item) -> (position: CGPoint, scale: CGFloat, opacity: Double, labelOpacity: Double) {
        let scale = Swift.max(canvasScale, 0.0001)
        let screen = CGPoint(
            x: focus.x + item.position.x * scale + canvasOffset.width,
            y: focus.y + item.position.y * scale + canvasOffset.height
        )
        let (drawn, rim) = lens.draw(screen, centre: focus)
        return (
            position: CGPoint(
                x: focus.x + (drawn.x - focus.x - canvasOffset.width) / scale,
                y: focus.y + (drawn.y - focus.y - canvasOffset.height) / scale
            ),
            scale: SynapsLens.scale(atRim: rim),
            opacity: SynapsLens.opacity(atRim: rim),
            labelOpacity: SynapsLens.labelOpacity(atDistance: hypot(drawn.x - focus.x, drawn.y - focus.y))
        )
    }
}

// MARK: - Contact Circle

struct ContactCircle: View {
    let user: ContactRecord
    /// Centre-to-centre distance of neighbours (`SynapsCloudLayout.pitch`).
    let pitch:        CGFloat
    let metrics:      ContactMetrics
    /// Size and opacity under the lens: full in the middle, smaller and dimmer at the edge.
    let lensScale:    CGFloat
    let lensOpacity:  Double
    /// The name shows only around the middle.
    let labelOpacity: Double
    var onTap: () -> Void

    @State private var touchMoved = false

    // MARK: Size
    //
    // Frequency score drives rendered diameter in the range [0.50 … 0.66] × pitch, small
    // enough that the name under each circle clears the row below.
    private var effectiveSize: CGFloat {
        let f = 0.50 + 0.16 * metrics.frequencyScore  // [0.50 … 0.66]
        return pitch * f
    }

    /// Max width for the name under the avatar — slightly wider than the circle.
    private var labelWidth: CGFloat {
        min(pitch * 0.92, max(effectiveSize * 1.35, 56))
    }

    var body: some View {
        // The circle is the view and stands exactly on its point; the name hangs under it as an
        // overlay, two points below the rim, and takes no room of its own. Until 2026-10-08 the
        // circle sat in a frame a fifth larger (room for the halo) with the name below that, so
        // the name floated off the circle and the circle stood above its point.
        ZStack {
            ZStack {
                if let data = user.avatar, let img = PlatformImage(data: data) {
                    Image(platformImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(accentColor.opacity(0.12))
                    IdenticonView(seed: user.id)
                }
            }
            .frame(width: effectiveSize, height: effectiveSize)
            .clipShape(Circle())
            .overlay(Circle().stroke(borderColor, lineWidth: metrics.activityRingLineWidth))
            // Soft halo — ambient “this node is live” (not a feed preview).
            .background {
                if metrics.showsActivityHalo && !user.isBlocked {
                    Circle()
                        .stroke(Color.CT.accent.opacity(0.28), lineWidth: 3)
                        .frame(width: effectiveSize * 1.14, height: effectiveSize * 1.14)
                }
            }

            if metrics.unreadCount > 0 {
                unreadBadge
                    .offset(x: effectiveSize * 0.34, y: -effectiveSize * 0.34)
            }
        }
        .overlay(alignment: .top) {
            // A name of two words wraps onto a second line rather than being cut.
            Text(user.resolvedDisplayName)
                .typesetting(asScriptOf: user.resolvedDisplayName)
                .font(CTFont.ui(10, weight: .medium))
                .foregroundStyle(user.isBlocked ? Color.CT.textDim : Color.CT.text)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(width: labelWidth)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: effectiveSize + 2)
                .opacity(labelOpacity)
                .allowsHitTesting(false)
        }
        .scaleEffect(lensScale)
        .opacity(lensOpacity)
        // Use DragGesture(minimumDistance: 0) so we can distinguish a stationary
        // tap from a drag that happens to end over the contact. Only fire onTap
        // when the finger hasn't moved more than 8 pt — matching the parent
        // canvas drag threshold — so pan/zoom never triggers navigation.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if hypot(value.translation.width, value.translation.height) > 8 {
                        touchMoved = true
                    }
                }
                .onEnded { value in
                    defer { touchMoved = false }
                    guard !touchMoved else { return }
                    guard hypot(value.translation.width, value.translation.height) <= 8 else { return }
                    onTap()
                }
        )
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var unreadBadge: some View {
        let n = metrics.unreadCount
        let label = n > 99 ? "99+" : "\(n)"
        return Text(label)
            .font(CTFont.ui(n > 9 ? 8 : 9, weight: .bold))
            .foregroundStyle(Color.CT.bg)
            .padding(.horizontal, n > 9 ? 4 : 0)
            .frame(minWidth: 15, minHeight: 15)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.CT.accent)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.CT.bg.opacity(0.35), lineWidth: 0.5)
            )
    }

    private var accessibilityLabel: String {
        let name = user.resolvedDisplayName
        if metrics.unreadCount > 0 {
            return "\(name), \(metrics.unreadCount)"
        }
        return name
    }

    // MARK: Style

    private var accentColor: Color { .hexagonAccent(for: user.id) }
    private var borderColor: Color {
        if user.isBlocked { return Color.red.opacity(0.55) }
        return metrics.activityRingColor
    }
}
