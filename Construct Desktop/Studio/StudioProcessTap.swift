//
//  StudioProcessTap.swift
//  Construct Desktop
//
//  The host's program, read from the DAW's process with a Core Audio process tap (macOS 14.2+):
//  no driver, no change of output device in the DAW, and the host still hears it. From the spike
//  (`Prototypes/StudioSpike`, construct-ios #307), feeding `StudioCapturePacketizer`.
//
//  A tap is read through a private aggregate device whose main sub-device is the default output,
//  so the tap runs on that device's clock. Without the system's audio-capture permission the tap
//  delivers silence rather than an error — the packetizer counts silent packets, and the stop line
//  in the log says how many there were.
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

final class StudioProcessTap: StudioProgramCapture {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let sourceDescription: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let tapFormat: AudioStreamBasicDescription
    private let queue = DispatchQueue(label: "studio.tap", qos: .userInteractive)
    private var packetizer: StudioCapturePacketizer?

    static func make() throws -> any StudioProgramCapture {
        // The DAW chosen in the call window, which stores it before Studio starts.
        guard let bundleID = StudioSource.stored() else { throw Failure(description: "no source chosen") }
        return try StudioProcessTap(bundleIdentifier: bundleID)
    }

    init(bundleIdentifier: String) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw Failure(description: "\(bundleIdentifier) is not running")
        }
        var pid = app.processIdentifier
        sourceDescription = "\(app.localizedName ?? bundleIdentifier) (pid \(pid))"

        var processObject = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                  UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject),
                       "translate pid")
        guard processObject != kAudioObjectUnknown else {
            throw Failure(description: "\(sourceDescription) has no audio process object — has it played anything yet?")
        }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = UUID()
        description.name = "Konstruct Studio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var asbd = AudioStreamBasicDescription()
        addr.mSelector = kAudioTapPropertyFormat
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "tap format")
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure(description: "unexpected tap format \(asbd)")
        }
        // The program is 48 kHz (`StudioAudioFormat.lossless`); a tap on a device at another rate
        // would be sent as if it were 48 kHz. Refused until resampling exists.
        guard asbd.mSampleRate == StudioAudioFormat.lossless.sampleRate else {
            AudioHardwareDestroyProcessTap(tapID)
            throw Failure(description: "the output device runs at \(Int(asbd.mSampleRate)) Hz; Studio needs 48000")
        }
        tapFormat = asbd

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Konstruct Studio tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        do {
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    deinit { stop() }

    func start(into packetizer: StudioCapturePacketizer) throws {
        self.packetizer = packetizer
        let channels = Int(tapFormat.mChannelsPerFrame)
        let interleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self, let packetizer = self.packetizer else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let base = first.mData else { return }
            if interleaved {
                let samples = UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self),
                                                  count: Int(first.mDataByteSize) / 4)
                packetizer.ingest(interleaved: samples, channels: channels)
            } else {
                let frames = Int(first.mDataByteSize) / 4
                let left = UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self), count: frames)
                let right = list.count > 1 ? list[1].mData.map {
                    UnsafeBufferPointer(start: $0.assumingMemoryBound(to: Float.self), count: frames)
                } : nil
                packetizer.ingest(left: left, right: right)
            }
        }, "create IO proc")
        try Self.check(AudioDeviceStart(aggregateID, procID), "start aggregate")
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let packetizer {
            Log.info(
                "Studio capture stopped: \(packetizer.packets) packets, \(packetizer.silentPackets) silent, "
                + "\(packetizer.clippedSamples) clipped samples",
                category: "Calls"
            )
            self.packetizer = nil
        }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device),
                  "default output")
        var uid: Unmanaged<CFString>?
        addr.mSelector = kAudioDevicePropertyDeviceUID
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid), "output uid")
        guard let uid else { throw Failure(description: "the default output has no UID") }
        return uid.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw Failure(description: "\(what): OSStatus \(status)") }
    }
}
