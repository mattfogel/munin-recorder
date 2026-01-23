import Foundation
import AVFoundation
import CoreMedia
import CoreAudio
import AudioToolbox

/// Captures system audio using Core Audio Taps (macOS 15+) and microphone via AVAudioEngine
/// This approach requires only Audio Recording permission, not Screen Recording
final class SystemAudioCapture: @unchecked Sendable {
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var micEngine: AVAudioEngine?

    private let systemAudioHandler: (CMSampleBuffer) -> Void
    private let microphoneHandler: (CMSampleBuffer) -> Void

    private let outputFormat: AVAudioFormat
    private var systemFormatDescription: CMAudioFormatDescription?
    private var micFormatDescription: CMAudioFormatDescription?
    private var systemSampleTime: Int64 = 0
    private var micSampleTime: Int64 = 0

    private var tapStreamFormat: AudioStreamBasicDescription?
    private var isCapturing = false

    init(
        systemAudioHandler: @escaping (CMSampleBuffer) -> Void,
        microphoneHandler: @escaping (CMSampleBuffer) -> Void
    ) async throws {
        self.systemAudioHandler = systemAudioHandler
        self.microphoneHandler = microphoneHandler

        // Output format: 48kHz mono float32 (matches AudioMixer expectations)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else {
            throw AudioCaptureError.failedToCreateFormat
        }
        self.outputFormat = format

        // Create format descriptions for CMSampleBuffer creation
        self.systemFormatDescription = try createFormatDescription()
        self.micFormatDescription = try createFormatDescription()

        // Set up the audio tap for system audio capture
        try await setupAudioTap()
    }

    private func createFormatDescription() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            throw AudioCaptureError.failedToCreateFormat
        }
        return desc
    }

    // MARK: - Core Audio Helpers

    private func getDefaultOutputDeviceID() throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioCaptureError.noOutputDevice
        }

        return deviceID
    }

    private func getDeviceUID(deviceID: AudioObjectID) throws -> String {
        var uid: CFString?
        var propertySize = UInt32(MemoryLayout<CFString?>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &uid
        )

        guard status == noErr, let deviceUID = uid as String? else {
            throw AudioCaptureError.failedToGetDeviceUID
        }

        return deviceUID
    }

    private func getTapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            tapID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &format
        )

        guard status == noErr else {
            throw AudioCaptureError.failedToGetTapFormat(status)
        }

        return format
    }

    // MARK: - Audio Tap Setup

    private func setupAudioTap() async throws {
        print("Munin: Setting up audio tap for global system audio capture")

        // Create tap description for global system audio (AudioTee pattern)
        // Empty processes array + isExclusive = true captures all system audio
        let tapDescription = CATapDescription()
        tapDescription.uuid = UUID()
        tapDescription.name = "Munin System Audio Tap"
        tapDescription.processes = []  // Empty = capture all processes
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.isMixdown = true
        tapDescription.isMono = false  // Keep stereo, we'll mix down later
        tapDescription.isExclusive = true  // Required for global capture
        tapDescription.deviceUID = nil  // System default output

        // Create the process tap
        var tapID: AudioObjectID = kAudioObjectUnknown

        let tapError = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapError == noErr else {
            print("Munin: Failed to create process tap, error: \(tapError) (\(fourCharCodeToString(tapError)))")
            throw AudioCaptureError.failedToCreateTap(tapError)
        }

        print("Munin: Created process tap with ID: \(tapID)")
        self.tapID = tapID

        // Get the tap's stream format
        let tapFormat = try getTapStreamFormat(tapID: tapID)
        self.tapStreamFormat = tapFormat
        print("Munin: Tap format - SR: \(tapFormat.mSampleRate), CH: \(tapFormat.mChannelsPerFrame), bits: \(tapFormat.mBitsPerChannel)")

        // Create aggregate device following AudioTee pattern:
        // Create device WITHOUT subdevice list, then add tap via property
        try createAggregateDevice(tapUUID: tapDescription.uuid)
    }

    private func fourCharCodeToString(_ code: OSStatus) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        if let str = String(bytes: bytes, encoding: .ascii), str.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            return "'\(str)'"
        }
        return "\(code)"
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        // Get the default output device to use as main subdevice
        let outputDeviceID = try getDefaultOutputDeviceID()
        let outputDeviceUID = try getDeviceUID(deviceID: outputDeviceID)

        let aggregateDeviceUID = "Munin_Aggregate_\(UUID().uuidString)"

        // Build aggregate device with both the output device and the tap
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Munin Audio Capture",
            kAudioAggregateDeviceUIDKey as String: aggregateDeviceUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUUID.uuidString
                ]
            ]
        ]

        var aggregateID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)

        guard status == noErr else {
            print("Munin: Failed to create aggregate device, error: \(status) (\(fourCharCodeToString(status)))")
            throw AudioCaptureError.failedToCreateAggregateDevice(status)
        }

        print("Munin: Created aggregate device with ID: \(aggregateID), output device: \(outputDeviceUID)")
        self.aggregateDeviceID = aggregateID
    }

    func startCapture() async throws {
        // Start system audio capture using IO proc (like AudioCap does)
        try startSystemAudioCapture()

        // Start microphone capture separately
        try startMicrophoneCapture()

        isCapturing = true
        print("Munin: Audio capture started (Core Audio Taps)")
    }

    private func startSystemAudioCapture() throws {
        guard let tapFormat = tapStreamFormat else {
            throw AudioCaptureError.failedToGetTapFormat(0)
        }

        // Create IO proc for the aggregate device
        var procID: AudioDeviceIOProcID?

        let ioBlock: AudioDeviceIOBlock = { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
            guard let self = self, self.isCapturing else { return }

            // Process input data (system audio from tap)
            let inputData = inInputData.pointee

            let bufferCount = Int(inputData.mNumberBuffers)
            guard bufferCount > 0 else { return }

            // Get the first buffer
            let buffer = inputData.mBuffers
            guard let data = buffer.mData else { return }

            let frameCount = Int(buffer.mDataByteSize) / Int(tapFormat.mBytesPerFrame)
            guard frameCount > 0 else { return }

            // Convert to float samples and create CMSampleBuffer
            self.processSystemAudioData(data: data, frameCount: frameCount, format: tapFormat)
        }

        var err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil, ioBlock)
        guard err == noErr, let deviceProcID = procID else {
            print("Munin: Failed to create IO proc, error: \(err)")
            throw AudioCaptureError.failedToCreateIOProc(err)
        }

        self.deviceProcID = deviceProcID

        // Start the device
        err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
        guard err == noErr else {
            print("Munin: Failed to start device, error: \(err)")
            throw AudioCaptureError.failedToStartDevice(err)
        }

        print("Munin: System audio capture started via IO proc")
    }

    private func processSystemAudioData(data: UnsafeMutableRawPointer, frameCount: Int, format: AudioStreamBasicDescription) {
        // Convert to float samples based on format
        var floatSamples: [Float]

        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Already float
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let channelCount = Int(format.mChannelsPerFrame)

            if channelCount == 1 {
                floatSamples = Array(UnsafeBufferPointer(start: floatPtr, count: frameCount))
            } else {
                // Mix down to mono
                floatSamples = [Float](repeating: 0, count: frameCount)
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += floatPtr[i * channelCount + ch]
                    }
                    floatSamples[i] = sum / Float(channelCount)
                }
            }
        } else {
            // Assume 32-bit int
            let intPtr = data.assumingMemoryBound(to: Int32.self)
            let channelCount = Int(format.mChannelsPerFrame)
            floatSamples = [Float](repeating: 0, count: frameCount)

            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += Float(intPtr[i * channelCount + ch]) / Float(Int32.max)
                }
                floatSamples[i] = sum / Float(channelCount)
            }
        }

        // Resample if needed (simple approach)
        if format.mSampleRate != 48000 {
            floatSamples = resample(samples: floatSamples, fromRate: format.mSampleRate, toRate: 48000)
        }

        // Create CMSampleBuffer
        guard let sampleBuffer = createSampleBuffer(
            samples: floatSamples,
            formatDescription: systemFormatDescription!,
            sampleTime: &systemSampleTime
        ) else { return }

        systemAudioHandler(sampleBuffer)
    }

    private func resample(samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        let ratio = toRate / fromRate
        let outputCount = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcIndexInt = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcIndexInt))

            if srcIndexInt + 1 < samples.count {
                output[i] = samples[srcIndexInt] * (1 - frac) + samples[srcIndexInt + 1] * frac
            } else if srcIndexInt < samples.count {
                output[i] = samples[srcIndexInt]
            }
        }

        return output
    }

    private func startMicrophoneCapture() throws {
        micEngine = AVAudioEngine()
        guard let engine = micEngine else {
            throw AudioCaptureError.engineNotInitialized
        }

        let inputNode = engine.inputNode

        // Use default input device (microphone)
        let inputFormat = inputNode.inputFormat(forBus: 0)
        print("Munin: Microphone input format: \(inputFormat)")

        // Create converter if needed
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        converter?.sampleRateConverterQuality = .max

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.processMicrophoneBuffer(buffer, converter: converter)
        }

        try engine.start()
        print("Munin: Microphone capture started")
    }

    private func processMicrophoneBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter?) {
        guard let samples = convertToFloatSamples(buffer: buffer, converter: converter) else { return }
        guard let sampleBuffer = createSampleBuffer(
            samples: samples,
            formatDescription: micFormatDescription!,
            sampleTime: &micSampleTime
        ) else { return }

        microphoneHandler(sampleBuffer)
    }

    private func convertToFloatSamples(buffer: AVAudioPCMBuffer, converter: AVAudioConverter?) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        if let converter = converter, converter.inputFormat != converter.outputFormat {
            // Need conversion
            let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
                return nil
            }

            var error: NSError?
            var inputConsumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

            if error != nil { return nil }

            return extractFloats(from: outputBuffer)
        } else {
            // Already in correct format or close enough
            return extractFloats(from: buffer)
        }
    }

    private func extractFloats(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let floatData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)

        // Mix down to mono if stereo
        if buffer.format.channelCount > 1 {
            var samples = [Float](repeating: 0, count: frameCount)
            let channelCount = Int(buffer.format.channelCount)
            for i in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += floatData[ch][i]
                }
                samples[i] = sum / Float(channelCount)
            }
            return samples
        } else {
            var samples = [Float](repeating: 0, count: frameCount)
            memcpy(&samples, floatData[0], frameCount * MemoryLayout<Float>.size)
            return samples
        }
    }

    private func createSampleBuffer(
        samples: [Float],
        formatDescription: CMAudioFormatDescription,
        sampleTime: inout Int64
    ) -> CMSampleBuffer? {
        let frameCount = samples.count
        let dataSize = frameCount * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        status = samples.withUnsafeBufferPointer { bufferPointer in
            CMBlockBufferReplaceDataBytes(
                with: bufferPointer.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }

        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let presentationTime = CMTime(value: sampleTime, timescale: 48000)

        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr else { return nil }

        sampleTime += Int64(frameCount)

        return sampleBuffer
    }

    func stopCapture() async {
        isCapturing = false

        // Stop and cleanup IO proc
        if let procID = deviceProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        // Clean up aggregate device
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        // Clean up tap
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        print("Munin: Audio capture stopped")
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case failedToCreateFormat
    case failedToCreateTap(OSStatus)
    case failedToCreateAggregateDevice(OSStatus)
    case failedToSetDevice(OSStatus)
    case engineNotInitialized
    case noOutputDevice
    case failedToGetDeviceUID
    case invalidAudioFormat
    case failedToGetTapFormat(OSStatus)
    case failedToCreateIOProc(OSStatus)
    case failedToStartDevice(OSStatus)

    var errorDescription: String? {
        switch self {
        case .failedToCreateFormat:
            return "Failed to create audio format"
        case .failedToCreateTap(let status):
            return "Failed to create audio tap: \(status)"
        case .failedToCreateAggregateDevice(let status):
            return "Failed to create aggregate device: \(status)"
        case .failedToSetDevice(let status):
            return "Failed to set audio device: \(status)"
        case .engineNotInitialized:
            return "Audio engine not initialized"
        case .noOutputDevice:
            return "No output device found"
        case .failedToGetDeviceUID:
            return "Failed to get device UID"
        case .invalidAudioFormat:
            return "Invalid audio format from capture device"
        case .failedToGetTapFormat(let status):
            return "Failed to get tap format: \(status)"
        case .failedToCreateIOProc(let status):
            return "Failed to create IO proc: \(status)"
        case .failedToStartDevice(let status):
            return "Failed to start audio device: \(status)"
        }
    }
}
