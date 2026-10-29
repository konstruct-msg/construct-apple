import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import StudioCore

/// The host's program audio, read from the DAW's process with a Core Audio process tap (macOS
/// 14.2+): no driver, no installer, no change of output device in the DAW. The tap is a stereo
/// mixdown of the process's output, private to this process, and does not mute what the host hears.
///
/// A tap is read through an aggregate device that contains it; the aggregate's main sub-device is
/// the default output, whose clock the tap then runs on. Captured Float32 is clipped to ±1 and
/// quantised to 24 bits — the same conversion a 24-bit render of the mix would make.
///
/// Without the system's audio-capture permission the tap delivers silence rather than an error,
/// so silence is reported (`silentPackets`).
public final class ProcessTapSource {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public let format: AudioFormat
    public let processDescription: String
    /// Called on the tap's queue with one packet (`format.samplesPerPacket` samples) and the frame
    /// index of its first frame, counted from the start of capture.
    public var onPacket: (([Int32], UInt64) -> Void)?
    public private(set) var silentPackets = 0
    public private(set) var packets = 0
    public private(set) var clippedSamples = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let tapFormat: AudioStreamBasicDescription
    private let queue = DispatchQueue(label: "studio.tap", qos: .userInteractive)
    private var pending: [Int32] = []
    private var nextFrame: UInt64 = 0

    public init(bundleIdentifier: String, framesPerPacket: UInt32 = 1024) throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard let app = apps.first else { throw Failure(description: "\(bundleIdentifier) is not running") }
        var pid = app.processIdentifier
        processDescription = "\(app.localizedName ?? bundleIdentifier) pid \(pid)"

        var processObject = AudioObjectID(kAudioObjectUnknown)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                  UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject),
                       "translate pid")
        guard processObject != kAudioObjectUnknown else {
            throw Failure(description: "\(processDescription) has no audio process object — has it played anything yet?")
        }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = UUID()
        description.name = "studio-spike"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        var asbd = AudioStreamBasicDescription()
        addr.mSelector = kAudioTapPropertyFormat
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "tap format")
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            throw Failure(description: "unexpected tap format \(asbd)")
        }
        tapFormat = asbd
        format = AudioFormat(sampleRate: asbd.mSampleRate, channels: 2, framesPerPacket: framesPerPacket)

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "studio-spike tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate")
    }

    deinit { stop() }

    public func start() throws {
        let channels = Int(tapFormat.mChannelsPerFrame)
        let interleaved = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            self.ingest(list, channels: channels, interleaved: interleaved)
        }, "create IO proc")
        try Self.check(AudioDeviceStart(aggregateID, procID), "start aggregate")
    }

    public func stop() {
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
    }

    private func ingest(_ list: UnsafeMutableAudioBufferListPointer, channels: Int, interleaved: Bool) {
        // The aggregate's input is the main sub-device's own inputs first, then the tap. An output
        // device with inputs (any audio interface) puts its preamp noise in `list.first`; the tap's
        // buffers are the last ones.
        let tapIndex = list.count - (interleaved ? 1 : channels)
        guard tapIndex >= 0, let base = list[tapIndex].mData else { return }
        let first = list[tapIndex]
        let peak = Float((1 << 23) - 1)
        func quantise(_ x: Float) -> Int32 {
            if x > 1 || x < -1 { clippedSamples += 1 }
            return Int32((max(-1, min(1, x)) * peak).rounded())
        }
        if interleaved {
            let frames = Int(first.mDataByteSize) / (4 * channels)
            let p = base.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                pending.append(quantise(p[f * channels]))
                pending.append(quantise(p[f * channels + min(1, channels - 1)]))
            }
        } else {
            let frames = Int(first.mDataByteSize) / 4
            let l = base.assumingMemoryBound(to: Float.self)
            let r = (channels > 1 ? list[tapIndex + 1].mData : base)!.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                pending.append(quantise(l[f]))
                pending.append(quantise(r[f]))
            }
        }
        let n = format.samplesPerPacket
        while pending.count >= n {
            let packet = Array(pending.prefix(n))
            pending.removeFirst(n)
            packets += 1
            if packet.allSatisfy({ $0 == 0 }) { silentPackets += 1 }
            onPacket?(packet, nextFrame)
            nextFrame += UInt64(format.framesPerPacket)
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
        return uid!.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw Failure(description: "\(what): OSStatus \(status)") }
    }
}
