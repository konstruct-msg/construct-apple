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
        .onAppear { computeSafetyNumber() }
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

    private func computeSafetyNumber() {
        guard let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty else {
            safetyNumber = NSLocalizedString("safety_numbers_unavailable", comment: "")
            return
        }
        safetyNumber = Self.compute(myDeviceId: myDeviceId, theirDeviceId: theirDeviceId)
    }

    /// Compute Safety Number from two device IDs.
    ///
    /// Algorithm matches Rust `compute_safety_number()` in `crypto/recovery.rs`:
    /// 1. Decode hex device IDs to bytes.
    /// 2. Sort lexicographically (ensures both parties compute the same value).
    /// 3. Iterate SHA-512 1024 rounds: hash = SHA-512(prev_hash || input).
    /// 4. Format first 24 bytes as 12 groups of 5 decimal digits (00000–99999).
    static func compute(myDeviceId: String, theirDeviceId: String) -> String {
        guard let myBytes = Data(hexString: myDeviceId),
              let theirBytes = Data(hexString: theirDeviceId) else {
            return ""
        }

        let (first, second) = myDeviceId < theirDeviceId
            ? (myBytes, theirBytes)
            : (theirBytes, myBytes)

        let input: Data = first + second
        var hash = Data(SHA512.hash(data: input))
        for _ in 1..<1024 {
            let combined: Data = hash + input
            hash = Data(SHA512.hash(data: combined))
        }

        return stride(from: 0, to: 24, by: 2).map { i -> String in
            let value = (UInt32(hash[i]) * 256 + UInt32(hash[i + 1])) % 100_000
            return String(format: "%05d", value)
        }.joined(separator: " ")
    }
}

// MARK: - Data hex decoding helper

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
