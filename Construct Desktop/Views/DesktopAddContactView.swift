//
//  DesktopAddContactView.swift
//  Construct Desktop
//
//  Add-contact sheet for macOS with four modes:
//   1. My QR Code  — show own timed invite QR
//   2. Scan Camera — live webcam QR detection
//   3. From File   — pick image / screenshot, detect QR via Vision
//   4. Paste Link  — type or paste invite URL
//
//  Requires in Desktop target Info.plist:
//    NSCameraUsageDescription — "Construct uses the camera to scan QR invite codes."
//

import SwiftUI
import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import Combine

// MARK: - Entry sheet

struct DesktopAddContactView: View {

    @Environment(AuthViewModel.self)      private var authViewModel
    @Environment(DeepLinkHandler.self)    private var deepLinkHandler
    @Environment(\.dismiss)              private var dismiss

    enum Mode: String, CaseIterable {
        case myQR    = "My QR"
        case camera  = "Scan Camera"
        case file    = "From File"
        case paste   = "Paste Link"

        var icon: String {
            switch self {
            case .myQR:   return "qrcode"
            case .camera: return "camera.viewfinder"
            case .file:   return "doc.viewfinder"
            case .paste:  return "doc.on.clipboard"
            }
        }
    }

    @State private var mode: Mode = .myQR
    @State private var resultMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──
            HStack {
                Text("Add Contact")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(DesktopTheme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(DesktopTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(DesktopTheme.backgroundPanel)

            Divider().overlay(DesktopTheme.separator)

            // ── Mode Picker ──
            HStack(spacing: 0) {
                ForEach(Mode.allCases, id: \.self) { m in
                    modePill(m)
                }
            }
            .padding(10)
            .background(DesktopTheme.backgroundPanel)

            Divider().overlay(DesktopTheme.separator)

            // ── Content ──
            Group {
                switch mode {
                case .myQR:   MyQRTab(onDone: { dismiss() })
                case .camera: CameraTab(onScanned: handleScannedCode)
                case .file:   FileTab(onScanned: handleScannedCode)
                case .paste:  PasteTab(onSubmit: handlePastedLink)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Result banner ──
            if let msg = resultMessage {
                Text(msg)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(msg.hasPrefix("✅") ? Color.green : Color.red)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(DesktopTheme.backgroundPanel)
            }
        }
        .frame(width: 460)
        .frame(minHeight: 500)
        .background(DesktopTheme.backgroundPrimary.ignoresSafeArea())
    }

    // MARK: - Mode Pill

    private func modePill(_ m: Mode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { mode = m }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: m.icon)
                    .font(.system(size: 16, weight: mode == m ? .semibold : .regular))
                Text(m.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(mode == m ? DesktopTheme.accent.opacity(0.15) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(mode == m ? DesktopTheme.accent.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
            .foregroundStyle(mode == m ? DesktopTheme.accent : DesktopTheme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Handlers

    private func handleScannedCode(_ code: String) {
        let normalized = normalizeCode(code)
        guard let url = URL(string: normalized) else {
            resultMessage = "❌ Invalid code format"
            return
        }
        let accepted = deepLinkHandler.handleURL(url)
        if accepted {
            resultMessage = "✅ Contact invite accepted"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
        } else {
            resultMessage = "❌ Not a valid Construct invite"
        }
    }

    private func handlePastedLink(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resultMessage = "❌ Empty input"
            return
        }
        guard let url = URL(string: trimmed) else {
            resultMessage = "❌ Not a valid URL"
            return
        }
        let accepted = deepLinkHandler.handleURL(url)
        if accepted {
            resultMessage = "✅ Processing invite…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
        } else {
            resultMessage = "❌ Not a valid Construct invite link"
        }
    }

    private func normalizeCode(_ code: String) -> String {
        var v = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fix double-scheme that some QR generators produce
        if v.hasPrefix("https://https://") { v = String(v.dropFirst("https://".count)) }
        // Bare domain pastes — prepend https
        if v.hasPrefix("konstruct.cc/") { v = "https://\(v)" }
        if v.hasPrefix("konstrukt.cc/") { v = "https://\(v)" }
        return v
    }
}

// MARK: - 1. My QR Tab

private struct MyQRTab: View {

    @Environment(AuthViewModel.self) private var authViewModel
    let onDone: () -> Void

    @State private var qrImage: NSImage? = nil
    @State private var errorMessage: String? = nil
    @State private var timeRemaining: TimeInterval = InviteConfig.ttlSeconds
    @State private var generatedAt: Date? = nil

    private let generator = InviteGenerator()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            if let img = qrImage {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 12)
            } else if let err = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(DesktopTheme.destructive)
                    Text(err)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(DesktopTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 220, height: 220)
            } else {
                ProgressView()
                    .frame(width: 220, height: 220)
            }

            // Countdown
            if timeRemaining > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("Expires in \(formatTime(timeRemaining))")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(timeRemaining < 60 ? DesktopTheme.destructive : DesktopTheme.textSecondary)
            } else {
                Button("Regenerate") { generate() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesktopTheme.accent)
            }

            Text("Show this to a contact so they can scan it")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesktopTheme.textTertiary)
        }
        .padding(24)
        .onAppear { generate() }
        .onReceive(timer) { _ in
            guard let at = generatedAt else { return }
            timeRemaining = max(InviteConfig.ttlSeconds - Date().timeIntervalSince(at), 0)
        }
    }

    private func generate() {
        qrImage = nil
        errorMessage = nil
        Task { await generateAsync() }
    }

    @MainActor
    private func generateAsync() async {
        guard let userId = authViewModel.currentUserId,
              let deviceId = KeychainManager.shared.loadDeviceID() else {
            errorMessage = "Device not registered"
            return
        }
        do {
            let link = try generator.generateDeepLink(
                userId: userId, deviceId: deviceId,
                server: ServerConfig.inviteHost, useHTTPS: false
            )
            qrImage = makeQRImage(from: link)
            generatedAt = Date()
            timeRemaining = InviteConfig.ttlSeconds
        } catch {
            errorMessage = "Failed to generate QR"
        }
    }

    private func makeQRImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    private func formatTime(_ t: TimeInterval) -> String {
        "\(Int(t) / 60):\(String(format: "%02d", Int(t) % 60))"
    }
}

// MARK: - 2. Camera Tab

private struct CameraTab: View {

    let onScanned: (String) -> Void

    @State private var permissionDenied = false
    @State private var scanner = DesktopQRScanner()

    var body: some View {
        VStack(spacing: 0) {
            if permissionDenied {
                permissionDeniedView
            } else {
                ZStack {
                    DesktopCameraPreview(scanner: scanner)
                        .cornerRadius(0)

                    // Corner brackets overlay
                    GeometryReader { geo in
                        let side: CGFloat = 180
                        let rect = CGRect(
                            x: (geo.size.width - side) / 2,
                            y: (geo.size.height - side) / 2,
                            width: side, height: side
                        )
                        ScannerBrackets(rect: rect)
                            .stroke(DesktopTheme.accent, lineWidth: 2.5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("Point camera at a Construct QR code")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesktopTheme.textSecondary)
                    .padding(.vertical, 12)
            }
        }
        .onAppear {
            checkPermission()
        }
        .onDisappear {
            scanner.stop()
        }
        .onChange(of: scanner.scannedCode) { _, code in
            if let code { onScanned(code) }
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(DesktopTheme.textSecondary)
            Text("Camera Access Required")
                .font(.system(.headline, design: .monospaced))
                .foregroundStyle(DesktopTheme.textPrimary)
            Text("Allow camera access in System Settings → Privacy & Security → Camera")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesktopTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
            .buttonStyle(.borderedProminent)
            .tint(DesktopTheme.accent)
        }
        .padding(32)
    }

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanner.start(onScanned: onScanned)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { scanner.start(onScanned: onScanned) }
                    else { permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }
}

// MARK: - 3. File Tab

private struct FileTab: View {

    let onScanned: (String) -> Void

    @State private var isProcessing = false
    @State private var dropTargeted = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(dropTargeted ? DesktopTheme.accent.opacity(0.08) : DesktopTheme.backgroundPanel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                dropTargeted ? DesktopTheme.accent : DesktopTheme.separator,
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                            )
                    )

                VStack(spacing: 12) {
                    if isProcessing {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.viewfinder")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(dropTargeted ? DesktopTheme.accent : DesktopTheme.textSecondary)
                        Text("Drop image here")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(DesktopTheme.textPrimary)
                        Text("PNG, JPG, screenshot")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DesktopTheme.textTertiary)
                    }
                }
            }
            .frame(height: 200)
            .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesktopTheme.destructive)
            }

            Button {
                openFilePicker()
            } label: {
                Label("Choose File…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(DesktopTheme.accent)
        }
        .padding(24)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        isProcessing = true
        errorMessage = nil
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        DispatchQueue.main.async { self.errorMessage = "❌ Cannot read file"; self.isProcessing = false }
                        return
                    }
                    detectQR(in: url)
                }
                return true
            } else if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data, let ciImage = CIImage(data: data) else {
                        DispatchQueue.main.async { self.errorMessage = "❌ Cannot decode image"; self.isProcessing = false }
                        return
                    }
                    detectQRFromCIImage(ciImage)
                }
                return true
            }
        }
        isProcessing = false
        return false
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.message = "Select a screenshot or image containing a Construct QR code"
        panel.prompt = "Scan"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isProcessing = true
            errorMessage = nil
            detectQR(in: url)
        }
    }

    private func detectQR(in url: URL) {
        guard let ciImage = CIImage(contentsOf: url) else {
            DispatchQueue.main.async { errorMessage = "❌ Cannot load image"; isProcessing = false }
            return
        }
        detectQRFromCIImage(ciImage)
    }

    private func detectQRFromCIImage(_ ciImage: CIImage) {
        let request = VNDetectBarcodesRequest { req, err in
            DispatchQueue.main.async {
                isProcessing = false
                if let obs = req.results?.compactMap({ $0 as? VNBarcodeObservation })
                                 .filter({ $0.symbology == .qr })
                                 .first,
                   let payload = obs.payloadStringValue {
                    onScanned(payload)
                } else {
                    errorMessage = "❌ No Construct QR code found in image"
                }
            }
        }
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }
}

// MARK: - 4. Paste Tab

private struct PasteTab: View {

    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("INVITE LINK")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesktopTheme.textTertiary)
                    .tracking(1.5)

                TextField("https://konstruct.cc/c/…  or  konstruct://…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(DesktopTheme.textPrimary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DesktopTheme.backgroundPanel)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        focused ? DesktopTheme.accent.opacity(0.6) : DesktopTheme.separator,
                                        lineWidth: 1
                                    )
                            )
                    )
                    .focused($focused)
                    .onSubmit { submit() }
            }

            HStack(spacing: 10) {
                Button {
                    if let str = NSPasteboard.general.string(forType: .string) { text = str }
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add Contact") { submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesktopTheme.accent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            Text("Supported formats: konstrukt:// deep link or https://konstruct.cc/c/ invite URL")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DesktopTheme.textTertiary)

            Spacer()
        }
        .padding(24)
        .onAppear { focused = true }
    }

    private func submit() {
        onSubmit(text)
    }
}

// MARK: - macOS Camera AVFoundation

/// macOS-native QR scanner using AVCaptureSession.
@Observable @MainActor
final class DesktopQRScanner: NSObject {
    var scannedCode: String? = nil
    private var session: AVCaptureSession? = nil
    private var onScannedCallback: ((String) -> Void)? = nil

    func start(onScanned: @escaping (String) -> Void) {
        self.onScannedCallback = onScanned
        let s = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              s.canAddInput(input) else { return }
        s.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard s.canAddOutput(output) else { return }
        s.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Filter requested types by what this platform actually supports.
        // On macOS, .qr is available but the full iOS set is not —
        // setting an unsupported type throws NSInvalidArgumentException.
        let supported = output.availableMetadataObjectTypes
        let requested: [AVMetadataObject.ObjectType] = [.qr]
        output.metadataObjectTypes = requested.filter { supported.contains($0) }

        self.session = s
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    func stop() {
        session?.stopRunning()
        session = nil
    }

    func makePreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let session else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }
}

extension DesktopQRScanner: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = obj.stringValue else { return }
        Task { @MainActor in
            if self.scannedCode == nil {
                self.scannedCode = code
                self.onScannedCallback?(code)
            }
        }
    }
}

/// NSViewRepresentable wrapping AVCaptureVideoPreviewLayer for macOS.
/// Uses a custom NSView subclass so the preview layer stays in sync with
/// the view's bounds even after window resize.
struct DesktopCameraPreview: NSViewRepresentable {
    let scanner: DesktopQRScanner

    func makeNSView(context: Context) -> CameraLayerView {
        let view = CameraLayerView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ nsView: CameraLayerView, context: Context) {
        // Attach the preview layer once; after that the CameraLayerView
        // automatically keeps it in sync via layout().
        if nsView.previewLayer == nil {
            Task { @MainActor in
                if let layer = scanner.makePreviewLayer() {
                    layer.frame = nsView.bounds
                    layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                    nsView.layer?.addSublayer(layer)
                    nsView.previewLayer = layer
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator {}

    // Custom NSView that keeps the preview layer filling the view on every layout pass.
    final class CameraLayerView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layout() {
            super.layout()
            previewLayer?.frame = bounds
        }
    }
}

// MARK: - Scanner brackets overlay (shared)

private struct ScannerBrackets: Shape {
    let rect: CGRect
    var length: CGFloat = 20

    func path(in bounds: CGRect) -> Path {
        var p = Path()
        let r = rect
        // TL
        p.move(to: CGPoint(x: r.minX, y: r.minY + length))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        // TR
        p.move(to: CGPoint(x: r.maxX - length, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + length))
        // BL
        p.move(to: CGPoint(x: r.minX, y: r.maxY - length))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + length, y: r.maxY))
        // BR
        p.move(to: CGPoint(x: r.maxX - length, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - length))
        return p
    }
}

// MARK: - Xcode Previews

#Preview("My QR") {
    DesktopAddContactView()
        .environment(AuthViewModel(context: PersistenceController.shared.container.viewContext))
        .environment(DeepLinkHandler())
}

#Preview("Paste Link") {
    // Show the Paste Link tab directly for fast layout iteration.
    PasteTab(onSubmit: { _ in })
        .frame(width: 460)
        .frame(minHeight: 300)
        .background(DesktopTheme.backgroundPrimary)
}

#Preview("File Drop") {
    FileTab(onScanned: { _ in })
        .frame(width: 460, height: 400)
        .background(DesktopTheme.backgroundPrimary)
}

#Preview("Scanner Brackets") {
    // Visual check for the corner-bracket overlay shape.
    GeometryReader { geo in
        let side: CGFloat = 180
        let rect = CGRect(
            x: (geo.size.width - side) / 2,
            y: (geo.size.height - side) / 2,
            width: side, height: side
        )
        ScannerBrackets(rect: rect)
            .stroke(DesktopTheme.accent, lineWidth: 2.5)
    }
    .frame(width: 300, height: 300)
    .background(Color.black)
}
