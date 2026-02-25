// DeviceAuthTestView.swift
// Development view for testing PoW and Device ID functionality

import SwiftUI

#if DEBUG
struct DeviceAuthTestView: View {
    @State private var isTestingPoW = false
    @State private var powResult: String = ""
    @State private var deviceIDResult: String = ""
    @State private var difficulty: UInt32 = 4
    @State private var testChallenge = "test_challenge_12345"
    
    var body: some View {
        NavigationView {
            List {
                // Device ID Test Section
                Section(header: Text("Device ID Generation")) {
                    Button(action: testDeviceID) {
                        HStack {
                            Image(systemName: "key.fill")
                            Text("Test Device ID")
                            Spacer()
                            if !deviceIDResult.isEmpty {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    
                    if !deviceIDResult.isEmpty {
                        Text(deviceIDResult)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                
                // PoW Test Section
                Section(header: Text("Proof of Work")) {
                    Picker("Difficulty", selection: $difficulty) {
                        Text("Easy (4 bits)").tag(UInt32(4))
                        Text("Normal (8 bits)").tag(UInt32(8))
                        Text("Hard (12 bits)").tag(UInt32(12))
                    }
                    
                    TextField("Challenge", text: $testChallenge)
                        .font(.system(.body, design: .monospaced))
                    
                    Button(action: testPoW) {
                        HStack {
                            if isTestingPoW {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "cpu")
                            }
                            Text(isTestingPoW ? "Computing..." : "Compute PoW")
                            Spacer()
                        }
                    }
                    .disabled(isTestingPoW)
                    
                    if !powResult.isEmpty {
                        Text(powResult)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                
                // Performance Info
                Section(header: Text("Expected Performance")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Difficulty 4:")
                                .bold()
                            Spacer()
                            Text("~20-30 seconds")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Difficulty 8:")
                                .bold()
                            Spacer()
                            Text("~3-5 minutes")
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Text("Difficulty 12:")
                                .bold()
                            Spacer()
                            Text("~1-2 hours")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.caption)
                }
                
                // Quick Test Buttons
                Section(header: Text("Quick Tests")) {
                    Button("Run All Tests") {
                        runAllTests()
                    }
                    
                    Button("Clear Results") {
                        powResult = ""
                        deviceIDResult = ""
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Device Auth Tests")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Test Functions
    
    private func testDeviceID() {
        print("\n🧪 Testing Device ID Generation...")
        
        // Test with zero key (known result)
        let zeroKey = Data(count: 32)
        let deviceID = DeviceIDManager.deriveDeviceID(from: zeroKey)
        
        let expected = "66687aadf862bd776c8fc18b8e9f8e20"
        let passed = deviceID == expected
        
        deviceIDResult = """
        Device ID: \(deviceID)
        Expected:  \(expected)
        Status: \(passed ? "✅ PASSED" : "❌ FAILED")
        
        Federated: \(DeviceIDManager.formatFederatedID(
            deviceID: deviceID,
            serverHostname: "ams.konstruct.cc"
        ))
        """
        
        print(deviceIDResult)
    }
    
    private func testPoW() {
        guard !isTestingPoW else { return }
        
        isTestingPoW = true
        powResult = "Computing... (difficulty \(difficulty))"
        
        print("\n🧪 Testing Proof of Work...")
        print("   Challenge: \(testChallenge)")
        print("   Difficulty: \(difficulty)")
        
        let startTime = Date()
        
        Task {
            let solution = await ProofOfWorkManager.compute(
                challenge: testChallenge,
                difficulty: difficulty
            )
            
            let elapsed = Date().timeIntervalSince(startTime)
            
            // Verify solution
            let isValid = ProofOfWorkManager.verify(
                challenge: testChallenge,
                solution: solution,
                difficulty: difficulty
            )
            
            await MainActor.run {
                powResult = """
                Nonce: \(solution.nonce)
                Hash: \(solution.hash)
                Time: \(String(format: "%.1f", elapsed))s
                Verified: \(isValid ? "✅" : "❌")
                """
                
                isTestingPoW = false
                
                print("✅ PoW Test Complete!")
                print("   Nonce: \(solution.nonce)")
                print("   Time: \(String(format: "%.1f", elapsed))s")
                print("   Valid: \(isValid)")
            }
        }
    }
    
    private func runAllTests() {
        testDeviceID()
        
        // Wait a bit then run PoW with low difficulty
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            difficulty = 4
            testPoW()
        }
    }
}

// MARK: - Preview

struct DeviceAuthTestView_Previews: PreviewProvider {
    static var previews: some View {
        DeviceAuthTestView()
    }
}
#endif
