//
//  PinDots.swift
//  ConstructUI
//
//  Copied verbatim from the app's PinDotsView.swift. Pure SwiftUI, no CT or app
//  dependencies — iOS-style PIN dot indicator with a hidden keyboard field.
//

import SwiftUI

struct PinDotsView: View {
    let length: Int
    @Binding var pin: String
    var onComplete: ((String) -> Void)?

    @FocusState private var isFocused: Bool
    @State private var shakeOffset: CGFloat = 0
    @State private var shakeAttemptId: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(0..<length, id: \.self) { index in
                    Circle()
                        .fill(index < pin.count ? Color.primary : Color.clear)
                        .overlay(
                            Circle().stroke(Color.primary.opacity(index < pin.count ? 1 : 0.3), lineWidth: 1.5)
                        )
                        .frame(width: 14, height: 14)
                        .scaleEffect(index == pin.count - 1 && pin.count > 0 ? 1.15 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: pin.count)
                }
            }
            .offset(x: shakeOffset)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }

            TextField("", text: $pin)
                #if canImport(UIKit)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
                .focused($isFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: pin) { _, newValue in
                    let digits = newValue.filter { $0.isNumber }
                    let clamped = String(digits.prefix(length))
                    if clamped != newValue { pin = clamped }
                    if clamped.count == length {
                        onComplete?(clamped)
                    }
                }
        }
        .onAppear { isFocused = true }
    }

    func triggerShake() {
        // Use shakeAttemptId to restart animation
    }

    static func shakeAnimation(_ offset: Binding<CGFloat>, _ attemptId: Binding<Int>) {
        attemptId.wrappedValue += 1
        withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) {
            offset.wrappedValue = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) {
                offset.wrappedValue = -8
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.08, dampingFraction: 0.2)) {
                offset.wrappedValue = 6
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.5)) {
                offset.wrappedValue = 0
            }
        }
    }
}

/// Wrapper that exposes shake trigger via binding
struct PinDotsField: View {
    let length: Int
    @Binding var pin: String
    @Binding var shake: Bool
    var onComplete: ((String) -> Void)?

    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        PinDotsView(length: length, pin: $pin, onComplete: onComplete)
            .offset(x: shakeOffset)
            .onChange(of: shake) { _, shouldShake in
                guard shouldShake else { return }
                runShake()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    shake = false
                }
            }
    }

    private func runShake() {
        let sequence: [(CGFloat, Double)] = [
            (10, 0.0), (-8, 0.08), (6, 0.16), (-4, 0.24), (0, 0.32)
        ]
        for (offset, delay) in sequence {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.08, dampingFraction: 0.3)) {
                    shakeOffset = offset
                }
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var pin = ""
        @State var shake = false
        var body: some View {
            VStack(spacing: 40) {
                Text("Enter PIN")
                    .font(.headline)
                PinDotsField(length: 6, pin: $pin, shake: $shake) { completed in
                    if completed != "123456" {
                        pin = ""
                        shake = true
                    }
                }
                Text("Entered: \(pin)")
                    .font(.caption)
            }
            .padding()
        }
    }
    return PreviewWrapper()
}
