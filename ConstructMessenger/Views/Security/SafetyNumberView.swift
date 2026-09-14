import SwiftUI
import CryptoKit

/// Full-screen Safety Number verification view.
///
/// Both parties compute the same 60-digit fingerprint from their device IDs.
/// An adversary performing a MITM attack would have a different device ID,
/// causing the Safety Numbers to mismatch.
struct SafetyNumberView: View {
    let theirDeviceId: String
    let theirDisplayName: String

    @Environment(\.dismiss) private var dismiss
    @State private var safetyNumber: String = ""
    @State private var copied = false

    private var formattedNumber: [String] {
        safetyNumber.split(separator: " ").map(String.init)
    }

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
                    numberGrid
                    Rectangle().fill(Color.CT.noise).frame(height: 1)

                    copyRow
                    Rectangle().fill(Color.CT.noise.opacity(0.4)).frame(height: 1)

                    warningBlock
                }
            }
        }
        .ctBackground()
        .onAppear { refreshSafetyNumber() }
    }

    // MARK: - Sections

    private var instructionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(">")
                    .font(CTFont.bold(12))
                    .foregroundStyle(Color.CT.accent)
                Text(NSLocalizedString("safety_numbers_verify_title", comment: "").uppercased())
                    .font(CTFont.bold(12))
                    .foregroundStyle(Color.CT.accent)
                    .tracking(2)
            }

            Text(String(format: NSLocalizedString("safety_numbers_instruction", comment: ""),
                        theirDisplayName))
                .font(CTFont.regular(13))
                .foregroundStyle(Color.CT.textDim)
                .lineSpacing(4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var numberGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(formattedNumber, id: \.self) { chunk in
                Text(chunk)
                    .font(CTFont.bold(16))
                    .foregroundStyle(Color.CT.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.CT.noise.opacity(0.25))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var copyRow: some View {
        Button {
            PlatformClipboard.copy(safetyNumber)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { copied = false }
            }
        } label: {
            HStack {
                Text(copied
                     ? NSLocalizedString("safety_numbers_copied", comment: "")
                     : NSLocalizedString("safety_numbers_copy", comment: ""))
                    .font(CTFont.regular(13))
                    .foregroundStyle(copied ? Color.CT.accent : Color.CT.text)
                Spacer()
                Text(copied ? "[✓]" : "[C]")
                    .font(CTFont.bold(13))
                    .foregroundStyle(copied ? Color.CT.accent : Color.CT.textDim)
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
                    .font(CTFont.bold(11))
                    .foregroundStyle(Color.CT.accent.opacity(0.7))
                Text(NSLocalizedString("safety_numbers_mismatch_header", comment: "").uppercased())
                    .font(CTFont.bold(11))
                    .foregroundStyle(Color.CT.accent.opacity(0.7))
                    .tracking(2)
            }

            Text(NSLocalizedString("safety_numbers_mismatch_body", comment: ""))
                .font(CTFont.regular(12))
                .foregroundStyle(Color.CT.textDim)
                .lineSpacing(4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Computation

    /// Named apart from the core's `computeSafetyNumber` on purpose: an unqualified call to a
    /// global of the same name from inside a method of that name is a recursion, not a call.
    private func refreshSafetyNumber() {
        guard let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty else {
            safetyNumber = NSLocalizedString("safety_numbers_unavailable", comment: "")
            return
        }
        // The core computes it. This view carried its own 1024-round SHA-512 until 2026-08-27,
        // under a comment promising the algorithm matched `crypto/recovery.rs` — which is the
        // comment that should have been this call. The two did agree for well-formed ids; they
        // disagreed for everything else, and the core was the one that was wrong (see below).
        guard let computed = computeSafetyNumber(
            myDeviceId: myDeviceId,
            theirDeviceId: theirDeviceId
        ) else {
            // `nil` means the core could not read one of the ids. It used to answer anyway, with
            // a number derived from empty bytes — so every unreadable id produced the *same*
            // number and two people who had verified nothing would have been shown a match.
            // There is no such thing as a partial safety number: either it is the value that
            // differs when a key was substituted, or there is nothing to show.
            Log.error("Safety number: the core declined to name a value for these ids", category: "Security")
            safetyNumber = NSLocalizedString("safety_numbers_unavailable", comment: "")
            return
        }
        safetyNumber = computed
    }
}

