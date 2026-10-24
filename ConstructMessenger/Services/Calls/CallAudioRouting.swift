//
//  CallAudioRouting.swift
//  Construct Messenger
//
//  Which microphone and output a call uses on a Mac.
//
//  The WebRTC build we ship cannot choose a device on macOS: its platform audio module lists no
//  devices at all, and its AVAudioEngine module lists only the system default
//  (`SetPlayoutDevice: Not implemented` in the binary). So a Mac call runs on the engine module and
//  the device is set on the engine's I/O unit from the module's observer, before each enable and
//  start — the engine is rebuilt more often than a call starts.
//
//  On a Mac one I/O unit carries both directions. A microphone on one device and an output on
//  another become a private aggregate of the two, as AVAudioEngine itself builds for the system
//  defaults. Apple's voice processing (VPIO) binds that unit back to the system defaults, so it is
//  off on macOS and echo cancellation is WebRTC's own — as it was with the platform module.
//

import Foundation

/// What the call's I/O unit is set to: the decision, without CoreAudio, so it is tested anywhere.
enum CallAudioRoute: Equatable {
    /// Nothing chosen (or the chosen device is gone): the engine follows the system.
    case system
    /// One device carries what the engine needs.
    case device(UInt32)
    /// Microphone and output on different devices: an aggregate of the two.
    case pair(input: UInt32, output: UInt32)

    struct Device: Equatable, Sendable {
        let id: UInt32
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
    }

    /// `inputUID` / `outputUID` are the saved choices, nil for "system default". A saved device that
    /// is no longer connected, or no longer has that direction, counts as not chosen.
    static func plan(
        inputUID: String?,
        outputUID: String?,
        recording: Bool,
        devices: [Device],
        defaultInput: UInt32?,
        defaultOutput: UInt32?
    ) -> CallAudioRoute {
        let input = inputUID.flatMap { uid in devices.first { $0.uid == uid && $0.hasInput } }
        let output = outputUID.flatMap { uid in devices.first { $0.uid == uid && $0.hasOutput } }
        guard recording else {
            return output.map { .device($0.id) } ?? .system
        }
        guard input != nil || output != nil,
              let inputId = input?.id ?? defaultInput,
              let outputId = output?.id ?? defaultOutput
        else { return .system }
        return inputId == outputId ? .device(inputId) : .pair(input: inputId, output: outputId)
    }
}

#if os(macOS)
import AVFAudio
import AudioToolbox
import CoreAudio
import WebRTC

/// The observer of the Mac call's audio module: sets the chosen devices on the engine's I/O unit.
/// Its callbacks arrive on WebRTC's audio thread, so its state is behind a lock.
final class CallAudioRouter: NSObject, RTCAudioDeviceModuleDelegate, @unchecked Sendable {
    static let shared = CallAudioRouter()

    static let inputKey = "call.audio.inputUID"
    static let outputKey = "call.audio.outputUID"

    private let lock = NSLock()
    /// The aggregate built for the current pair, and which pair it is.
    private var aggregate: (key: String, id: AudioDeviceID)?

    // MARK: Devices

    /// The Mac's audio devices, without hidden ones and without private aggregates — ours, the one
    /// AVAudioEngine builds and Studio's tap are visible to this process only, and are not choices.
    static func devices() -> [CallAudioRoute.Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                  uint32(id, kAudioDevicePropertyIsHidden) != 1,
                  !isPrivateAggregate(id)
            else { return nil }
            let hasInput = hasStreams(id, kAudioObjectPropertyScopeInput)
            let hasOutput = hasStreams(id, kAudioObjectPropertyScopeOutput)
            guard hasInput || hasOutput else { return nil }
            return CallAudioRoute.Device(
                id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid,
                hasInput: hasInput, hasOutput: hasOutput
            )
        }
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject), selector)
        return id.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    // MARK: Applying

    private func route(recording: Bool) -> CallAudioRoute {
        CallAudioRoute.plan(
            inputUID: UserDefaults.standard.string(forKey: Self.inputKey),
            outputUID: UserDefaults.standard.string(forKey: Self.outputKey),
            recording: recording,
            devices: Self.devices(),
            defaultInput: Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
            defaultOutput: Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    private func apply(_ engine: AVAudioEngine, recording: Bool) {
        let target: AudioDeviceID
        switch route(recording: recording) {
        case .system:
            return
        case .device(let id):
            target = id
        case .pair(let input, let output):
            guard let id = pairDevice(input: input, output: output) else { return }
            target = id
        }
        // One unit carries both directions on a Mac. With recording on it must be reached through
        // the input node, or the engine replaces it with its own aggregate of the system defaults;
        // without recording the input node is not touched, which would turn the microphone on.
        guard let unit = recording ? engine.inputNode.audioUnit : engine.outputNode.audioUnit else { return }
        if Self.currentDevice(unit) == target { return }
        var device = target
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.error("call audio device \(target) not set: \(status)", category: "Calls")
        }
    }

    private func pairDevice(input: AudioDeviceID, output: AudioDeviceID) -> AudioDeviceID? {
        guard let inputUID = Self.string(input, kAudioDevicePropertyDeviceUID),
              let outputUID = Self.string(output, kAudioDevicePropertyDeviceUID)
        else { return nil }
        let key = inputUID + "|" + outputUID
        lock.lock()
        defer { lock.unlock() }
        if let aggregate, aggregate.key == key { return aggregate.id }
        destroyAggregateLocked()
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Konstruct call",
            kAudioAggregateDeviceUIDKey: "konstruct.call.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            // The output keeps the clock; the microphone is resampled to it.
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: true],
                [kAudioSubDeviceUIDKey: outputUID],
            ],
        ]
        var id: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else {
            Log.error("call audio aggregate not created: \(status)", category: "Calls")
            return nil
        }
        aggregate = (key, id)
        return id
    }

    private func destroyAggregateLocked() {
        if let aggregate { AudioHardwareDestroyAggregateDevice(aggregate.id) }
        aggregate = nil
    }

    /// A choice made during a call: the engine reads devices only when it is enabled, so playout
    /// and recording are restarted as they were.
    func reapply(_ module: RTCAudioDeviceModule) {
        let (playing, recording) = (module.playing, module.recording)
        if recording { module.stopRecording() }
        if playing { module.stopPlayout() }
        if playing {
            module.initPlayout()
            module.startPlayout()
        }
        if recording {
            module.initRecording()
            module.startRecording()
        }
    }

    // MARK: RTCAudioDeviceModuleDelegate

    func audioDeviceModule(_ module: RTCAudioDeviceModule, didReceiveSpeechActivityEvent event: RTCSpeechActivityEvent) {}

    func audioDeviceModule(_ module: RTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int { 0 }

    func audioDeviceModule(
        _ module: RTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool, isRecordingEnabled: Bool, isVoiceProcessingEnabled: Bool
    ) -> Int {
        apply(engine, recording: isRecordingEnabled)
        return 0
    }

    /// Also here: stopping recording restarts the engine for playout without enabling it again.
    func audioDeviceModule(
        _ module: RTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool, isRecordingEnabled: Bool
    ) -> Int {
        apply(engine, recording: isRecordingEnabled)
        return 0
    }

    func audioDeviceModule(
        _ module: RTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool, isRecordingEnabled: Bool
    ) -> Int { 0 }

    func audioDeviceModule(
        _ module: RTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool, isRecordingEnabled: Bool
    ) -> Int { 0 }

    func audioDeviceModule(_ module: RTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        lock.lock()
        destroyAggregateLocked()
        lock.unlock()
        return 0
    }

    // With an observer set, the module leaves wiring the engine's graph to it.
    func audioDeviceModule(
        _ module: RTCAudioDeviceModule, engine: AVAudioEngine,
        configureInputFromSource source: AVAudioNode?, toDestination destination: AVAudioNode,
        format: AVAudioFormat, context: [AnyHashable: Any]
    ) -> Int {
        if let source { engine.connect(source, to: destination, format: format) }
        return 0
    }

    func audioDeviceModule(
        _ module: RTCAudioDeviceModule, engine: AVAudioEngine,
        configureOutputFromSource source: AVAudioNode, toDestination destination: AVAudioNode?,
        format: AVAudioFormat, context: [AnyHashable: Any]
    ) -> Int {
        if let destination { engine.connect(source, to: destination, format: format) }
        return 0
    }

    func audioDeviceModuleDidUpdateDevices(_ module: RTCAudioDeviceModule) {}

    // MARK: CoreAudio reads

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        guard uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate else { return false }
        var address = address(kAudioAggregateDevicePropertyComposition)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    private static func currentDevice(_ unit: AudioUnit) -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr
        else { return nil }
        return device
    }
}
#endif
