//
//  QRScannerView.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 30.12.2025.
//

import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onCodeScanned: (String) -> Void

    @StateObject private var scanner = QRCodeScanner()
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingPermissionAlert = false
    @State private var showDebugInfo = false

    private var testMode: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview (full screen including safe areas)
                QRCodeScannerViewRepresentable(scanner: scanner)
                    .ignoresSafeArea()

                // Dim overlay + corner brackets, computed from safe-area content size
                GeometryReader { geo in
                    let scanSize = min(geo.size.width * 0.72, 260.0)
                    let scanRect = CGRect(
                        x: (geo.size.width - scanSize) / 2,
                        y: (geo.size.height - scanSize) / 2 - 30,
                        width: scanSize,
                        height: scanSize
                    )

                    ScannerDimOverlay(scanRect: scanRect)
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                        .ignoresSafeArea()

                    ScannerCornerBrackets(scanRect: scanRect)
                        .stroke(Color.AppBrand.button, lineWidth: 3)
                }

                // UI panels
                VStack {
                    if showDebugInfo {
                        debugPanel.padding(.top, 60)
                    }
                    Spacer()
                    bottomPanel.padding(.bottom, 60)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showDebugInfo.toggle()
                    } label: {
                        Image(systemName: showDebugInfo ? "info.circle.fill" : "info.circle")
                            .foregroundColor(.white)
                    }
                }
            }
            .onAppear { checkCameraPermission() }
            .onDisappear { scanner.stopScanning() }
            .alert("camera_access_required", isPresented: $showingPermissionAlert) {
                Button("open_settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("cancel", role: .cancel) { dismiss() }
            } message: {
                Text("allow_camera_access_for_qr")
            }
            .onChange(of: scanner.scannedCode) { _, newValue in
                if let code = newValue { handleScannedCode(code) }
            }
            .alert("error", isPresented: $showingError) {
                Button("ok") { dismiss() }
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Bottom Panel

    private var bottomPanel: some View {
        VStack(spacing: 14) {
            Text("scan_qr_code")
                .font(.headline)
                .foregroundColor(.white)

            Text("position_qr_code_within_frame")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))

            Button { handleClipboardPaste() } label: {
                Label("paste_invite_link", systemImage: "doc.on.clipboard")
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.15))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }

            if testMode {
                Button { simulateQRCodeScan() } label: {
                    Label("Simulate QR Scan", systemImage: "camera.viewfinder")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Debug Panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera Debug Info")
                .font(.headline)
                .foregroundColor(.white)

            Divider().background(Color.white)

            debugInfoRow("Session Ready",
                         value: scanner.isSessionReady ? "✅ Yes" : "❌ No",
                         color: scanner.isSessionReady ? .green : .red)
            debugInfoRow("Permission", value: permissionStatusString, color: permissionStatusColor)
            debugInfoRow("Device", value: deviceInfo, color: .white)

            if let deviceName = AVCaptureDevice.default(for: .video)?.localizedName {
                debugInfoRow("Camera", value: deviceName, color: .white)
            }

            Button { simulateQRCodeScan() } label: {
                HStack {
                    Image(systemName: "qrcode")
                    Text("Test Scan")
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .padding(.top, 4)
        }
        .padding()
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func debugInfoRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label + ":").font(.caption).foregroundColor(.gray)
            Text(value).font(.caption).foregroundColor(color)
        }
    }

    // MARK: - Helpers

    private var permissionStatusString: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: "✅ Authorized"
        case .notDetermined: "⏳ Not Determined"
        case .denied: "❌ Denied"
        case .restricted: "⚠️ Restricted"
        @unknown default: "❓ Unknown"
        }
    }

    private var permissionStatusColor: Color {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .green
        case .notDetermined: .orange
        case .denied, .restricted: .red
        @unknown default: .gray
        }
    }

    private var deviceInfo: String {
        #if targetEnvironment(simulator)
        "📱 Simulator (no camera)"
        #else
        "📱 Real Device"
        #endif
    }

    private func simulateQRCodeScan() {
        let generator = InviteGenerator()
        guard let userId = SessionManager.shared.currentUserId,
              let deviceId = KeychainManager.shared.loadDeviceID() else {
            print("⚠️ No authenticated user — cannot simulate invite")
            return
        }
        do {
            let testCode = try generator.generateDeepLink(userId: userId, deviceId: deviceId, useHTTPS: false)
            print("🧪 QRScannerView: Simulating Dynamic Invite scan")
            handleScannedCode(testCode)
        } catch {
            print("❌ Failed to generate test invite: \(error)")
        }
    }

    private func handleClipboardPaste() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            errorMessage = NSLocalizedString("clipboard_no_valid_invite", comment: "")
            showingError = true
            return
        }
        Log.debug("📋 QRScannerView: pasting from clipboard: \(text.prefix(80))", category: "QRScannerView")
        handleScannedCode(text)
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scanner.startScanning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { scanner.startScanning() }
                    else { showingPermissionAlert = true }
                }
            }
        case .denied, .restricted:
            showingPermissionAlert = true
        @unknown default:
            showingPermissionAlert = true
        }
    }

    private func handleScannedCode(_ code: String) {
        scanner.stopScanning()
        let normalized = normalizeScannedCode(code)
        Log.debug("📷 QRScannerView: scanned=\(code.prefix(120)), normalized=\(normalized.prefix(120))", category: "QRScannerView")

        if normalized.lowercased().hasPrefix("https://konstruct.cc/c/") ||
           normalized.lowercased().hasPrefix("https://konstruct.cc/add") ||
           normalized.lowercased().hasPrefix("https://web.konstruct.cc/add") ||
           normalized.lowercased().hasPrefix(InviteConfig.qrCodePrefixScheme) {
            onCodeScanned(normalized)
        } else if isBase64Like(normalized) {
            onCodeScanned("konstruct://add?invite=\(normalized)")
        } else {
            errorMessage = NSLocalizedString("invalid_qr_code_construct", comment: "")
            showingError = true
        }
    }

    private func isBase64Like(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= QRScannerConfig.minBase64Length else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        return trimmed.rangeOfCharacter(from: allowed.inverted) == nil
    }

    private func normalizeScannedCode(_ code: String) -> String {
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("https://https://") {
            value = value.replacingOccurrences(of: "https://https://", with: "https://")
        } else if value.hasPrefix("http://https://") {
            value = value.replacingOccurrences(of: "http://https://", with: "https://")
        }
        if value.hasPrefix("konstruct.cc/") { value = "https://\(value)" }
        return value
    }
}

// MARK: - Scanner Overlay Shapes

/// Full-screen dark mask with a rounded-rect hole cut out at scanRect (even-odd fill rule)
private struct ScannerDimOverlay: Shape {
    let scanRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: scanRect, cornerSize: CGSize(width: 12, height: 12))
        return path
    }
}

/// Four L-shaped corner brackets drawn around scanRect
private struct ScannerCornerBrackets: Shape {
    let scanRect: CGRect
    var length: CGFloat = 24
    var radius: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = scanRect

        // Top-left
        p.move(to: CGPoint(x: r.minX, y: r.minY + length))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + length, y: r.minY))

        // Top-right
        p.move(to: CGPoint(x: r.maxX - length, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + length))

        // Bottom-left
        p.move(to: CGPoint(x: r.minX, y: r.maxY - length))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.maxY), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + length, y: r.maxY))

        // Bottom-right
        p.move(to: CGPoint(x: r.maxX - length, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - radius), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - length))

        return p
    }
}

private enum QRScannerConfig {
    static let minBase64Length = 40
}

// MARK: - QR Code Scanner Logic
class QRCodeScanner: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    @Published var scannedCode: String?
    @Published var isSessionReady = false  // ✅ NEW: Track when session is ready

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    func startScanning() {
        // ✅ FIX: Setup session SYNCHRONOUSLY first
        let session = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            print("❌ No video capture device available")
            return
        }

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            print("❌ Failed to create video input: \(error)")
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        } else {
            print("❌ Cannot add video input")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            print("❌ Cannot add metadata output")
            return
        }

        // ✅ FIX: Set captureSession BEFORE starting - this is key!
        self.captureSession = session

        // ✅ FIX: Notify that session is ready for preview layer
        DispatchQueue.main.async {
            self.isSessionReady = true
            print("✅ Camera session ready")
        }

        // ✅ Only startRunning() is async - setup is sync
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            print("✅ Camera session started")
        }
    }

    func stopScanning() {
        captureSession?.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        if let metadataObject = metadataObjects.first {
            guard let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject else { return }
            guard let stringValue = readableObject.stringValue else { return }

            // Only trigger once
            if scannedCode == nil {
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                scannedCode = stringValue
            }
        }
    }

    func getPreviewLayer() -> AVCaptureVideoPreviewLayer? {
        guard let captureSession = captureSession else { return nil }

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspectFill

        // Set orientation to portrait since app is portrait-only
        if let connection = previewLayer.connection {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 90 // portrait
            }
        }

        return previewLayer
    }
}

// MARK: - UIViewRepresentable for Camera Preview
struct QRCodeScannerViewRepresentable: UIViewRepresentable {
    @ObservedObject var scanner: QRCodeScanner

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        print("📱 makeUIView called - creating camera view")
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        print("🔄 updateUIView called - isSessionReady: \(scanner.isSessionReady), hasLayer: \(context.coordinator.previewLayer != nil)")

        // ✅ FIX: Only add preview layer when session is ready AND not already added
        if scanner.isSessionReady && context.coordinator.previewLayer == nil {
            if let previewLayer = scanner.getPreviewLayer() {
                print("✅ Adding preview layer to view")
                previewLayer.frame = uiView.bounds
                uiView.layer.insertSublayer(previewLayer, at: 0)
                context.coordinator.previewLayer = previewLayer
            } else {
                print("❌ getPreviewLayer returned nil")
            }
        }

        // Update preview layer frame when view size changes
        if let previewLayer = context.coordinator.previewLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = uiView.bounds
            CATransaction.commit()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

#Preview {
    QRScannerView { code in
        print("Scanned: \(code)")
    }
}
