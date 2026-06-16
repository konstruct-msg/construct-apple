import SwiftUI

struct ChatNavBarView: View {
    let title: String
    let subtitle: String?
    let contactKTStatus: KTStatus
    let isEditMode: Bool
    let canStartCall: Bool
    let isSearchActive: Bool
    let onBack: () -> Void
    let onOpenProfile: () -> Void
    let onDoneEdit: () -> Void
    let onStartCall: () -> Void
    /// Always non-nil so the layout is stable; rendered only when
    /// `CallsFeature.isVideoEnabled` is true.
    let onStartVideoCall: () -> Void
    let onToggleSearch: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color.CT.accent)
            }

            Button(action: onOpenProfile) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased())
                        .font(CTFont.bold(13))
                        .foregroundColor(Color.CT.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(CTFont.regular(10))
                            .foregroundColor(Color.CT.accentDim)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: subtitle)
            }
            .buttonStyle(.plain)

            ktBadge

            Spacer()

            if isEditMode {
                Button(action: onDoneEdit) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(CTFont.regular(13))
                        .foregroundColor(Color.CT.accent)
                }
            } else {
                if canStartCall {
                    if CallsFeature.isVideoEnabled {
                        Button(action: onStartVideoCall) {
                            Image(systemName: "video.fill")
                                .font(.system(size: CTLayout.navIconSizeLg, weight: .medium))
                                .foregroundColor(Color.CT.accent)
                        }
                    }
                    Button(action: onStartCall) {
                        Image(systemName: "phone")
                            .font(.system(size: CTLayout.navIconSizeLg, weight: .medium))
                            .foregroundColor(Color.CT.accent)
                    }
                }
                Button(action: onToggleSearch) {
                    Image(systemName: isSearchActive ? "xmark" : "magnifyingglass")
                        .font(.system(size: CTLayout.navIconSize, weight: .medium))
                        .foregroundColor(Color.CT.accent)
                }
            }
        }
        .padding(.horizontal, CTLayout.edgePad)
        .frame(height: CTLayout.navBarHeight)
        .ctBorderBottom()
    }

    @ViewBuilder private var ktBadge: some View {
        switch contactKTStatus {
        case .verified:
            Image(systemName: "checkmark.circle.fill")
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.accent)
        case .keyChanged, .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(CTFont.bold(11))
                .foregroundColor(Color.CT.danger)
        case .unverified:
            EmptyView()
        }
    }
}
