import SwiftUI
import CryptoKit

/// Full-screen Safety Number verification view.
///
/// Both parties compute the same 60-digit fingerprint from their device IDs.
/// An adversary performing a MITM attack would have a different device ID,
/// causing the Safety Numbers to mismatch.
///
/// One number per device of the contact: a session is a ratchet between two devices, and a
/// substituted key is a device of its own — comparing one device says nothing about the others
/// (`decisions/a-new-device-is-the-security-event.md`).
struct SafetyNumberView: View {
    let theirDeviceIds: [String]
    let theirDisplayName: String

    @Environment(\.dismiss) private var dismiss
    /// Device id → the number, or nil where the core could not name one.
    @State private var numbers: [String: String] = [:]
    @State private var copiedDeviceId: String?

    var body: some View {
        VStack(spacing: 0) {
            CTNavBar(
                title: NSLocalizedString("safety_numbers", comment: ""),
                showBack: true,
                backAction: { dismiss() }
            ) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
            Rectangle().fill(Color.CT.noise).frame(height: 1)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    instructionBlock

                    Rectangle().fill(Color.CT.noise).frame(height: 1)
                    if theirDeviceIds.isEmpty {
                        unavailableRow
                        Rectangle().fill(Color.CT.noise).frame(height: 1)
                    }
                    ForEach(theirDeviceIds, id: \.self) { deviceId in
                        if theirDeviceIds.count > 1 {
                            deviceHeader(deviceId)
                        }
                        if let number = numbers[deviceId] {
                            numberGrid(number)
                            Rectangle().fill(Color.CT.noise).frame(height: 1)
                            copyRow(number, deviceId: deviceId)
                        } else {
                            unavailableRow
                        }
                        Rectangle().fill(Color.CT.noise.opacity(0.4)).frame(height: 1)
                    }

                    warningBlock
                }
            }
        }
        .ctBackground()
        .onAppear { refreshSafetyNumbers() }
    }

    // MARK: - Sections

    private var instructionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(">")
                    .font(CTFont.ui(12, weight: .bold))
                    .foregroundStyle(Color.CT.accent)
                Text(NSLocalizedString("safety_numbers_verify_title", comment: "").uppercased())
                    .font(CTFont.ui(12, weight: .bold))
                    .foregroundStyle(Color.CT.accent)
                    .tracking(2)
            }

            Text(String(format: NSLocalizedString("safety_numbers_instruction", comment: ""),
                        theirDisplayName))
                .font(CTFont.body)
                .foregroundStyle(Color.CT.textDim)
                .lineSpacing(4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func deviceHeader(_ deviceId: String) -> some View {
        Text(String(format: NSLocalizedString("safety_numbers_device_fmt", comment: ""), String(deviceId.prefix(8))))
            .font(CTFont.badge)
            .foregroundStyle(Color.CT.textDim)
            .tracking(2)
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }

    private var unavailableRow: some View {
        Text(NSLocalizedString("safety_numbers_unavailable", comment: ""))
            .font(CTFont.body)
            .foregroundStyle(Color.CT.textDim)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
    }

    private func numberGrid(_ number: String) -> some View {
        // Indexed: two chunks of one number can be equal, and an id of the chunk would drop one.
        let chunks = number.split(separator: " ").map(String.init)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                Text(chunk)
                    .font(CTFont.mono(16, weight: .bold))
                    .foregroundStyle(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.CT.noise.opacity(0.25))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private func copyRow(_ number: String, deviceId: String) -> some View {
        let copied = copiedDeviceId == deviceId
        return Button {
            PlatformClipboard.copy(number)
            withAnimation { copiedDeviceId = deviceId }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { if copiedDeviceId == deviceId { copiedDeviceId = nil } }
            }
        } label: {
            HStack {
                Text(copied
                     ? NSLocalizedString("safety_numbers_copied", comment: "")
                     : NSLocalizedString("safety_numbers_copy", comment: ""))
                    .font(CTFont.body)
                    .foregroundStyle(copied ? Color.CT.accent : Color.CT.text)
                Spacer()
                // The copy action's own affordance. `[C]` needed a legend.
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(copied ? Color.CT.accent : Color.CT.textDim)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private var warningBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("!")
                    .font(CTFont.badge)
                    .foregroundStyle(Color.CT.accent.opacity(0.7))
                Text(NSLocalizedString("safety_numbers_mismatch_header", comment: "").uppercased())
                    .font(CTFont.badge)
                    .foregroundStyle(Color.CT.accent.opacity(0.7))
                    .tracking(2)
            }

            Text(NSLocalizedString("safety_numbers_mismatch_body", comment: ""))
                .font(CTFont.secondary)
                .foregroundStyle(Color.CT.textDim)
                .lineSpacing(4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Computation

    /// Named apart from the core's `computeSafetyNumber` on purpose: an unqualified call to a
    /// global of the same name from inside a method of that name is a recursion, not a call.
    private func refreshSafetyNumbers() {
        guard let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty else {
            numbers = [:]
            return
        }
        var out: [String: String] = [:]
        for theirDeviceId in theirDeviceIds {
            // The core computes it. This view carried its own 1024-round SHA-512 until 2026-08-27,
            // under a comment promising the algorithm matched `crypto/recovery.rs` — which is the
            // comment that should have been this call.
            //
            // `nil` means the core could not read one of the ids. It used to answer anyway, with
            // a number derived from empty bytes — so every unreadable id produced the *same*
            // number and two people who had verified nothing would have been shown a match.
            // There is no such thing as a partial safety number: either it is the value that
            // differs when a key was substituted, or there is nothing to show.
            if let computed = computeSafetyNumber(myDeviceId: myDeviceId, theirDeviceId: theirDeviceId) {
                out[theirDeviceId] = computed
            } else {
                Log.error("Safety number: the core declined to name a value for \(theirDeviceId.prefix(8))…", category: "Security")
            }
        }
        numbers = out
    }
}
