import AudioToolbox
import Foundation

/// The program audio's PCM form on both ends: interleaved `Int32`, one 24-bit sample in the low
/// 24 bits, sign-extended (range ±2^23). The converters below are fed the same values shifted into
/// the high bits, which is how AudioToolbox spells "24 valid bits in a 32-bit container".
public struct AudioFormat: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: UInt32
    /// Frames per FLAC packet, and so per data-channel message. 1024 at 48 kHz is 21.3 ms.
    public var framesPerPacket: UInt32

    public init(sampleRate: Double = 48_000, channels: UInt32 = 2, framesPerPacket: UInt32 = 1024) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
    }

    public var samplesPerPacket: Int { Int(framesPerPacket * channels) }

    var pcm: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 24, mReserved: 0)
    }

    var flac: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatFLAC,
            mFormatFlags: kAppleLosslessFormatFlag_24BitSourceData, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: 0, mReserved: 0)
    }
}

public struct CodecError: Error, CustomStringConvertible {
    public let what: String
    public let status: OSStatus
    public var description: String { "\(what): OSStatus \(status)" }
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CodecError(what: what, status: status) }
}

/// Returned by an input proc that has nothing queued. Any non-zero value works; AudioToolbox
/// passes it back out of `AudioConverterFillComplexBuffer`, with whatever it could produce.
private let inputExhausted: OSStatus = 0x6578_6831 // 'exh1'

/// An AudioConverter driven as a stream. FLAC's encoder holds input back (it emits nothing for the
/// first packet it is given), so a packet in does not mean a packet out: input is queued, and the
/// buffer handed to the converter stays alive until the converter asks for the next one, which is
/// the lifetime AudioToolbox requires of it.
private final class StreamingConverter {
    let ref: AudioConverterRef
    let channels: UInt32
    /// Input units per queued chunk: frames for PCM input, 1 packet for compressed input.
    private var queue: [(bytes: [UInt8], units: UInt32)] = []
    private var current: UnsafeMutableRawBufferPointer?
    private var currentDescription = AudioStreamPacketDescription()
    private let compressedInput: Bool

    init(from: AudioStreamBasicDescription, to: AudioStreamBasicDescription, what: String) throws {
        var a = from, b = to
        var r: AudioConverterRef?
        try check(AudioConverterNew(&a, &b, &r), what)
        ref = r!
        channels = from.mChannelsPerFrame
        compressedInput = from.mFormatID != kAudioFormatLinearPCM
    }

    deinit {
        current?.deallocate()
        AudioConverterDispose(ref)
    }

    func enqueue(_ bytes: [UInt8], units: UInt32) { queue.append((bytes, units)) }

    /// Pull output packets until the converter has nothing more to give from what is queued.
    /// `capacity` is the byte size of one output packet's buffer.
    func drain(capacity: UInt32, outputPacketsPerCall: UInt32, wantDescriptions: Bool) throws -> [Data] {
        var produced: [Data] = []
        while true {
            var out = [UInt8](repeating: 0, count: Int(capacity))
            var packets = outputPacketsPerCall
            var description = AudioStreamPacketDescription()
            let status = out.withUnsafeMutableBytes { outRaw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: channels, mDataByteSize: capacity, mData: outRaw.baseAddress))
                let me = Unmanaged.passUnretained(self).toOpaque()
                if wantDescriptions {
                    return AudioConverterFillComplexBuffer(ref, streamingInput, me, &packets, &list, &description)
                }
                return AudioConverterFillComplexBuffer(ref, streamingInput, me, &packets, &list, nil)
            }
            guard status == noErr || status == inputExhausted else { throw CodecError(what: "convert", status: status) }
            if packets == 0 { return produced }
            if wantDescriptions {
                let start = Int(description.mStartOffset)
                produced.append(Data(out[start..<start + Int(description.mDataByteSize)]))
            } else {
                // PCM: `packets` counts frames, and a short pull is a short buffer.
                produced.append(Data(out.prefix(Int(packets * channels * 4))))
            }
            if status == inputExhausted { return produced }
        }
    }

    fileprivate func supply(_ ioPackets: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>,
                            _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        current?.deallocate()
        current = nil
        guard !queue.isEmpty else {
            ioPackets.pointee = 0
            return inputExhausted
        }
        let next = queue.removeFirst()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: next.bytes.count, alignment: 16)
        buffer.copyMemory(from: UnsafeRawBufferPointer(start: next.bytes, count: next.bytes.count))
        current = buffer
        ioPackets.pointee = next.units
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mData = buffer.baseAddress
        ioData.pointee.mBuffers.mDataByteSize = UInt32(next.bytes.count)
        ioData.pointee.mBuffers.mNumberChannels = channels
        if compressedInput {
            currentDescription = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                              mDataByteSize: UInt32(next.bytes.count))
            withUnsafeMutablePointer(to: &currentDescription) { outDescription?.pointee = $0 }
        }
        return noErr
    }
}

private func streamingInput(
    _ converter: AudioConverterRef,
    _ ioPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    Unmanaged<StreamingConverter>.fromOpaque(context!).takeUnretainedValue().supply(ioPackets, ioData, outDescription)
}

public final class FlacEncoder {
    public let format: AudioFormat
    private let converter: StreamingConverter
    private let maxPacketSize: UInt32

    public init(format: AudioFormat = AudioFormat()) throws {
        self.format = format
        converter = try StreamingConverter(from: format.pcm, to: format.flac, what: "FLAC encoder")
        var size: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioConverterGetProperty(converter.ref, kAudioConverterPropertyMaximumOutputPacketSize,
                                            &propSize, &size), "max packet size")
        maxPacketSize = size
    }

    /// What the decoder needs before the first packet (STREAMINFO).
    public func magicCookie() throws -> Data {
        var size: UInt32 = 0
        try check(AudioConverterGetPropertyInfo(converter.ref, kAudioConverterCompressionMagicCookie, &size, nil),
                  "cookie size")
        var bytes = [UInt8](repeating: 0, count: Int(size))
        try check(AudioConverterGetProperty(converter.ref, kAudioConverterCompressionMagicCookie, &size, &bytes),
                  "cookie")
        return Data(bytes.prefix(Int(size)))
    }

    /// Queue one packet of exactly `format.samplesPerPacket` samples; returns the FLAC packets the
    /// encoder released, in order — none for the first call, then one per call.
    public func encode(_ samples: [Int32]) throws -> [Data] {
        precondition(samples.count == format.samplesPerPacket, "a packet is exactly framesPerPacket frames")
        let shifted = samples.map { $0 << 8 }
        let bytes = shifted.withUnsafeBytes { [UInt8]($0) }
        converter.enqueue(bytes, units: format.framesPerPacket)
        return try converter.drain(capacity: maxPacketSize, outputPacketsPerCall: 1, wantDescriptions: true)
    }
}

public final class FlacDecoder {
    public let format: AudioFormat
    private let converter: StreamingConverter

    public init(format: AudioFormat = AudioFormat(), magicCookie: Data) throws {
        self.format = format
        converter = try StreamingConverter(from: format.flac, to: format.pcm, what: "FLAC decoder")
        var cookie = [UInt8](magicCookie)
        try check(AudioConverterSetProperty(converter.ref, kAudioConverterDecompressionMagicCookie,
                                            UInt32(cookie.count), &cookie), "set cookie")
    }

    /// One FLAC packet in; the PCM samples released, interleaved. A decoder that holds a packet
    /// back returns fewer here and catches up later, so callers treat the result as a stream.
    public func decode(_ packet: Data) throws -> [Int32] {
        converter.enqueue([UInt8](packet), units: 1)
        let bytes = UInt32(format.samplesPerPacket * 4)
        return try converter.drain(capacity: bytes, outputPacketsPerCall: format.framesPerPacket, wantDescriptions: false)
            .flatMap { data in data.withUnsafeBytes { raw in raw.bindMemory(to: Int32.self).map { $0 >> 8 } } }
    }
}
