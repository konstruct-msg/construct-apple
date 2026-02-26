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
    @State private var showDebugInfo = false  // ✅ Debug panel

    // ✅ Test mode - автоматически включается на симуляторе
    private var testMode: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false  // Измени на true для ручного тестирования на реальном устройстве
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Camera preview
                QRCodeScannerViewRepresentable(scanner: scanner)
                    .ignoresSafeArea()

                // Overlay with scanning frame
                VStack {
                    // ✅ Debug info at top
                    if showDebugInfo {
                        debugPanel
                            .padding(.top, 60)
                    }

                    Spacer()

                    VStack(spacing: 16) {
                        Text("scan_qr_code")
                            .font(.headline)
                            .foregroundColor(.white)

                        Text("position_qr_code_within_frame")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))

                        // ✅ Test mode button
                        if testMode {
                            Button {
                                simulateQRCodeScan()
                            } label: {
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
                    .padding(.bottom, 60)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") {
                        dismiss()
                    }
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
            .onAppear {
                checkCameraPermission()
            }
            .onDisappear {
                scanner.stopScanning()
            }
            .alert("camera_access_required", isPresented: $showingPermissionAlert) {
                Button("open_settings") {
                    if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsURL)
                    }
                }
                Button("cancel", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("allow_camera_access_for_qr")
            }
            .onChange(of: scanner.scannedCode) { _, newValue in
                if let code = newValue {
                    handleScannedCode(code)
                }
            }
            .alert("error", isPresented: $showingError) {
                Button("ok") {
                    dismiss()
                }
            } message: {
                Text(errorMessage)
            }
        }
    }

    // ✅ Debug panel
    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera Debug Info")
                .font(.headline)
                .foregroundColor(.white)

            Divider()
                .background(Color.white)

            debugInfoRow(
                label: "Session Ready",
                value: scanner.isSessionReady ? "✅ Yes" : "❌ No",
                color: scanner.isSessionReady ? .green : .red
            )

            debugInfoRow(
                label: "Permission",
                value: permissionStatusString,
                color: permissionStatusColor
            )

            debugInfoRow(
                label: "Device",
                value: deviceInfo,
                color: .white
            )

            if let deviceName = AVCaptureDevice.default(for: .video)?.localizedName {
                debugInfoRow(
                    label: "Camera",
                    value: deviceName,
                    color: .white
                )
            }

            // Test button
            Button {
                simulateQRCodeScan()
            } label: {
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

    private func debugInfoRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.caption)
                .foregroundColor(color)
        }
    }

    private var permissionStatusString: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "✅ Authorized"
        case .notDetermined: return "⏳ Not Determined"
        case .denied: return "❌ Denied"
        case .restricted: return "⚠️ Restricted"
        @unknown default: return "❓ Unknown"
        }
    }

    private var permissionStatusColor: Color {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .green
        case .notDetermined: return .orange
        case .denied, .restricted: return .red
        @unknown default: return .gray
        }
    }

    private var deviceInfo: String {
        #if targetEnvironment(simulator)
        return "📱 Simulator (no camera)"
        #else
        return "📱 Real Device"
        #endif
    }

    // ✅ Simulate QR code scan for testing
    private func simulateQRCodeScan() {
        // Generate Dynamic Invite for testing using the CURRENT user's real keys.
        // This lets the server verify the signature against a real registered user.
        let generator = InviteGenerator()
        guard let realUserId = SessionManager.shared.currentUserId,
              let realDeviceId = KeychainManager.shared.loadDeviceID() else {
            print("⚠️ No authenticated user — cannot simulate invite")
            return
        }

        do {
            let testCode = try generator.generateDeepLink(
                userId: realUserId,
                deviceId: realDeviceId,
                useHTTPS: false
            )

            print("🧪 QRScannerView: Simulating Dynamic Invite scan")
            print("   Generated URL: \(testCode.prefix(100))...")
            print("   UserId: \(realUserId)")
            print("   DeviceId: \(realDeviceId)")
            handleScannedCode(testCode)
        } catch {
            print("❌ Failed to generate test invite: \(error)")
        }
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("✅ Camera permission granted")
            scanner.startScanning()

        case .notDetermined:
            print("⏳ Requesting camera permission")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("✅ Camera permission granted")
                        scanner.startScanning()
                    } else {
                        print("❌ Camera permission denied")
                        showingPermissionAlert = true
                    }
                }
            }

        case .denied, .restricted:
            print("❌ Camera permission denied or restricted")
            showingPermissionAlert = true

        @unknown default:
            print("⚠️ Unknown camera permission status")
            showingPermissionAlert = true
        }
    }

    private func handleScannedCode(_ code: String) {
        scanner.stopScanning()

        let normalized = normalizeScannedCode(code)
        Log.debug("📷 QRScannerView: scanned=\(code.prefix(120))..., normalized=\(normalized.prefix(120))...", category: "QRScannerView")

        // Support both legacy and Dynamic Invite formats
        if normalized.lowercased().hasPrefix("https://konstruct.cc/c/") ||
           normalized.lowercased().hasPrefix("https://konstruct.cc/add") ||
           normalized.lowercased().hasPrefix("https://web.konstruct.cc/add") ||
           normalized.lowercased().hasPrefix(InviteConfig.qrCodePrefixScheme) {
            onCodeScanned(normalized)
        } else if isBase64Like(normalized) {
            let wrapped = "konstruct://add?invite=\(normalized)"
            onCodeScanned(wrapped)
        } else {
            errorMessage = NSLocalizedString("invalid_qr_code_construct", comment: "Error message for invalid QR code")
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
        if value.hasPrefix("konstruct.cc/") {
            value = "https://\(value)"
        }
        return value
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
