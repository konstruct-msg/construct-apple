//
//  OrientationView.swift
//  Construct Messenger
//
//  Post-registration product orientation — short explanation of Construct’s
//  unusual contact model and app map. Not identity registration.
//

import SwiftUI

// MARK: - Page model

private enum OrientationPage: Int, CaseIterable, Identifiable {
    case identity
    case addNode
    case map

    var id: Int { rawValue }

    var titleKey: String {
        switch self {
        case .identity: return "orientation_page1_title"
        case .addNode:  return "orientation_page2_title"
        case .map:      return "orientation_page3_title"
        }
    }

    var bodyKey: String {
        switch self {
        case .identity: return "orientation_page1_body"
        case .addNode:  return "orientation_page2_body"
        case .map:      return "orientation_page3_body"
        }
    }

    var captionKey: String {
        switch self {
        case .identity: return "orientation_page1_caption"
        case .addNode:  return "orientation_page2_caption"
        case .map:      return "orientation_page3_caption"
        }
    }
}

// MARK: - Root

/// Three-page first-run guide. Skip is always available for users who already know the product.
struct OrientationView: View {
    /// When true (first-run path), finishing switches the main UI to Synaps.
    var openSynapsOnFinish: Bool = true
    /// Optional dismiss hook (e.g. Settings sheet replay).
    var onFinished: (() -> Void)? = nil

    @AppStorage(OrientationStore.completedKey) private var orientationCompleted = false
    @State private var page: OrientationPage = .identity

    private var isLastPage: Bool { page == .map }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            #if os(iOS)
            TabView(selection: $page) {
                ForEach(OrientationPage.allCases) { p in
                    pageContent(p)
                        .tag(p)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            #else
            // Desktop: no swipe pager — Continue / Skip drive navigation.
            pageContent(page)
                .id(page)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif

            bottomChrome
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ctBackground()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Text(NSLocalizedString("orientation_section_label", comment: "").uppercased())
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.accent)
                .tracking(2)

            Spacer()

            Button {
                finish()
            } label: {
                Text(NSLocalizedString("orientation_skip", comment: "").uppercased())
                    .font(CTFont.regular(13))
                    .foregroundColor(Color.CT.textDim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("orientation_skip", comment: ""))
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var bottomChrome: some View {
        VStack(spacing: 20) {
            pageDots

            CTButton(
                label: NSLocalizedString(
                    isLastPage ? "orientation_enter" : "orientation_next",
                    comment: ""
                ).uppercased()
            ) {
                if isLastPage {
                    finish()
                } else {
                    advance()
                }
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 36)
        .padding(.top, 8)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(OrientationPage.allCases) { p in
                Circle()
                    .fill(p == page ? Color.CT.accent : Color.CT.noise)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: NSLocalizedString("orientation_page_a11y", comment: ""),
                page.rawValue + 1,
                OrientationPage.allCases.count
            )
        )
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageContent(_ p: OrientationPage) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                Spacer(minLength: 12)

                illustration(for: p)
                    .frame(height: 160)
                    .frame(maxWidth: .infinity)

                VStack(spacing: 12) {
                    Text(NSLocalizedString(p.titleKey, comment: "").uppercased())
                        .font(CTFont.bold(18))
                        .foregroundColor(Color.CT.text)
                        .tracking(2)
                        .multilineTextAlignment(.center)

                    Text(NSLocalizedString(p.bodyKey, comment: ""))
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.text)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(NSLocalizedString(p.captionKey, comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundColor(Color.CT.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 420)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func illustration(for p: OrientationPage) -> some View {
        switch p {
        case .identity:
            identityIllustration
        case .addNode:
            addNodeIllustration
        case .map:
            mapIllustration
        }
    }

    private var identityIllustration: some View {
        VStack(spacing: 16) {
            ZStack {
                HexagonShape()
                    .stroke(Color.CT.accent.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 88, height: 88)
                HexagonShape()
                    .fill(Color.CT.bgMsg)
                    .frame(width: 72, height: 72)
                Image(systemName: "key.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(Color.CT.accent)
            }
            HStack(spacing: 6) {
                Image(systemName: "iphone")
                    .font(.system(size: 12, weight: .medium))
                Text(NSLocalizedString("orientation_page1_visual_label", comment: "").uppercased())
                    .font(CTFont.regular(10))
                    .tracking(1)
            }
            .foregroundColor(Color.CT.textDim)
        }
    }

    private var addNodeIllustration: some View {
        HStack(spacing: 12) {
            orientationPathCard(
                icon: "qrcode",
                titleKey: "orientation_page2_path_qr_title",
                subtitleKey: "orientation_page2_path_qr_sub"
            )
            Text(NSLocalizedString("orientation_or", comment: "").uppercased())
                .font(CTFont.regular(10))
                .foregroundColor(Color.CT.textDim)
            orientationPathCard(
                icon: "magnifyingglass",
                titleKey: "orientation_page2_path_search_title",
                subtitleKey: "orientation_page2_path_search_sub"
            )
        }
        .padding(.horizontal, 20)
    }

    private func orientationPathCard(icon: String, titleKey: String, subtitleKey: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(Color.CT.accent)
                .frame(height: 28)
            Text(NSLocalizedString(titleKey, comment: "").uppercased())
                .font(CTFont.bold(11))
                .foregroundColor(Color.CT.text)
                .tracking(1)
                .multilineTextAlignment(.center)
            Text(NSLocalizedString(subtitleKey, comment: ""))
                .font(CTFont.regular(10))
                .foregroundColor(Color.CT.textDim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(Color.CT.bgMsg)
        .overlay(
            Rectangle().stroke(Color.CT.noise, lineWidth: 0.5)
        )
    }

    private var mapIllustration: some View {
        VStack(spacing: 0) {
            mapRow(icon: "message", titleKey: "orientation_map_streams", subKey: "orientation_map_streams_sub")
            Rectangle().fill(Color.CT.noise).frame(height: 1)
            mapRow(icon: "circle.grid.cross", titleKey: "orientation_map_synaps", subKey: "orientation_map_synaps_sub")
            Rectangle().fill(Color.CT.noise).frame(height: 1)
            mapRow(icon: "gearshape", titleKey: "orientation_map_settings", subKey: "orientation_map_settings_sub")
        }
        .background(Color.CT.bgMsg)
        .overlay(
            Rectangle().stroke(Color.CT.noise, lineWidth: 0.5)
        )
        .padding(.horizontal, 28)
        .frame(maxWidth: 360)
    }

    private func mapRow(icon: String, titleKey: String, subKey: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color.CT.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString(titleKey, comment: "").uppercased())
                    .font(CTFont.bold(12))
                    .foregroundColor(Color.CT.text)
                    .tracking(1)
                Text(NSLocalizedString(subKey, comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundColor(Color.CT.textDim)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, CTLayout.sectionGap)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func advance() {
        guard let next = OrientationPage(rawValue: page.rawValue + 1) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            page = next
        }
    }

    private func finish() {
        orientationCompleted = true
        if openSynapsOnFinish {
            // Deliver after MainTab mounts so the subscriber exists.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openSynapsTab, object: nil)
            }
        }
        onFinished?()
    }
}

// MARK: - Simple hex (matches CT avatar language without depending on avatar size APIs)

private struct HexagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY
        let r = min(w, h) / 2
        var path = Path()
        for i in 0..<6 {
            let angle = CGFloat(i) * .pi / 3 - .pi / 2
            let point = CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("Orientation") {
    OrientationView()
}
#endif
