import Foundation
import AVFoundation
import CoreMedia
import Accelerate

/// Mixes system audio and microphone audio using direct sample mixing with Accelerate
final class AudioMixer: @unchecked Sendable {
    // Output format: 48kHz mono float32
    private let sampleRate: Double = 48000
    private let channelCount: UInt32 = 1

    // Volume levels - prioritize voice clarity for transcription
    private let systemAudioGain: Float = 0.65
    private let microphoneGain: Float = 1.0

    // Ring buffers for each source
    private var systemBuffer: [Float] = []
    private var micBuffer: [Float] = []

    // Processing
    private let processingQueue = DispatchQueue(label: "com.munin.audiomixer", qos: .userInteractive)
    private let bufferSize = 8192 // Samples per output buffer (~170ms at 48kHz to absorb timing jitter)
    private let crossfadeLength = 64 // Samples for crossfade (~1.3ms) to eliminate clicks

    // Startup buffering - wait for both sources before mixing
    private let startupBufferThreshold = 9600 // ~200ms at 48kHz
    private var startupComplete = false

    // Timing
    private var outputSampleTime: Int64 = 0

    // Previous output for crossfading between buffers
    private var previousOutputTail: [Float] = []

    // Output
    var outputHandler: ((CMSampleBuffer) -> Void)?

    // Format descriptions cached for efficiency
    private var outputFormatDescription: CMAudioFormatDescription?
    private var systemAudioConverter: AVAudioConverter?
    private var microphoneConverter: AVAudioConverter?
    private lazy var outputFormat: AVAudioFormat = {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
    }()

    init() throws {
        // Create output format description
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &outputFormatDescription
        )

        guard status == noErr else {
            throw AudioMixerError.failedToCreateFormat
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self] in
            self?.appendToBuffer(sampleBuffer, isSystem: true)
        }
    }

    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self] in
            self?.appendToBuffer(sampleBuffer, isMicrophone: true)
        }
    }

    private func appendToBuffer(_ sampleBuffer: CMSampleBuffer, isSystem: Bool = false, isMicrophone: Bool = false) {
        guard let samples = extractFloatSamples(from: sampleBuffer, isSystem: isSystem, isMicrophone: isMicrophone) else {
            return
        }

        if isSystem {
            systemBuffer.append(contentsOf: samples)
        } else if isMicrophone {
            micBuffer.append(contentsOf: samples)
        }

        // Process when we have enough samples from both sources
        processBuffers()
    }

    private func extractFloatSamples(from sampleBuffer: CMSampleBuffer, isSystem: Bool, isMicrophone: Bool) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        // Create source format
        guard let sourceFormat = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        // Check if we need conversion
        let needsConversion = sourceFormat.sampleRate != sampleRate ||
                             sourceFormat.channelCount != channelCount ||
                             sourceFormat.commonFormat != .pcmFormatFloat32

        if !needsConversion {
            // Direct copy - already in correct format
            let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: frameCount)
            var samples = [Float](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                samples[i] = floatPointer[i]
            }
            return applySampleGain(samples, isSystem: isSystem, isMicrophone: isMicrophone)
        }

        // Need to convert - create or reuse converter
        let converter: AVAudioConverter?
        if isSystem {
            if systemAudioConverter == nil || systemAudioConverter?.inputFormat != sourceFormat {
                systemAudioConverter = AVAudioConverter(from: sourceFormat, to: outputFormat)
                // Configure high-quality resampling
                systemAudioConverter?.sampleRateConverterQuality = .max
                systemAudioConverter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            }
            converter = systemAudioConverter
        } else {
            if microphoneConverter == nil || microphoneConverter?.inputFormat != sourceFormat {
                microphoneConverter = AVAudioConverter(from: sourceFormat, to: outputFormat)
                // Configure high-quality resampling
                microphoneConverter?.sampleRateConverterQuality = .max
                microphoneConverter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            }
            converter = microphoneConverter
        }

        guard let audioConverter = converter else {
            return nil
        }

        // Create source buffer
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy data to source buffer based on format
        if let floatData = sourceBuffer.floatChannelData {
            memcpy(floatData[0], data, min(totalLength, Int(frameCount) * MemoryLayout<Float>.size))
        } else if let int16Data = sourceBuffer.int16ChannelData {
            memcpy(int16Data[0], data, min(totalLength, Int(frameCount) * MemoryLayout<Int16>.size))
        } else if let int32Data = sourceBuffer.int32ChannelData {
            memcpy(int32Data[0], data, min(totalLength, Int(frameCount) * MemoryLayout<Int32>.size))
        }

        // Calculate output frame count
        let ratio = sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        // Convert
        var error: NSError?
        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        audioConverter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if error != nil {
            return nil
        }

        // Extract float samples from output buffer
        guard let floatChannelData = outputBuffer.floatChannelData else {
            return nil
        }

        let count = Int(outputBuffer.frameLength)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = floatChannelData[0][i]
        }

        return applySampleGain(samples, isSystem: isSystem, isMicrophone: isMicrophone)
    }

    private func applySampleGain(_ samples: [Float], isSystem: Bool, isMicrophone: Bool) -> [Float] {
        var output = samples
        let gain = isSystem ? systemAudioGain : microphoneGain
        var gainValue = gain
        vDSP_vsmul(samples, 1, &gainValue, &output, 1, vDSP_Length(samples.count))
        return output
    }

    private func processBuffers() {
        // Startup buffering: wait for both sources to accumulate enough samples
        // This prevents initial sync issues when sources start at different times
        if !startupComplete {
            if systemBuffer.count >= startupBufferThreshold && micBuffer.count >= startupBufferThreshold {
                startupComplete = true
            } else {
                return // Keep accumulating
            }
        }

        // Mix only when BOTH sources have enough data
        // This prevents silence padding which causes discontinuities
        while systemBuffer.count >= bufferSize && micBuffer.count >= bufferSize {
            var mixedSamples = [Float](repeating: 0, count: bufferSize)

            // Extract exactly bufferSize samples from each source
            let systemSamples = Array(systemBuffer.prefix(bufferSize))
            systemBuffer.removeFirst(bufferSize)

            let micSamples = Array(micBuffer.prefix(bufferSize))
            micBuffer.removeFirst(bufferSize)

            // Mix: add system audio
            vDSP_vadd(mixedSamples, 1, systemSamples, 1, &mixedSamples, 1, vDSP_Length(bufferSize))

            // Mix: add microphone audio
            vDSP_vadd(mixedSamples, 1, micSamples, 1, &mixedSamples, 1, vDSP_Length(bufferSize))

            // Apply crossfade from previous buffer to smooth transitions
            if !previousOutputTail.isEmpty {
                applyCrossfade(from: previousOutputTail, to: &mixedSamples)
            }

            // Clip to prevent distortion
            var minVal: Float = -1.0
            var maxVal: Float = 1.0
            vDSP_vclip(mixedSamples, 1, &minVal, &maxVal, &mixedSamples, 1, vDSP_Length(bufferSize))

            // Save tail for next crossfade
            previousOutputTail = Array(mixedSamples.suffix(crossfadeLength))

            // Create output sample buffer
            if let sampleBuffer = createOutputSampleBuffer(from: mixedSamples) {
                outputHandler?(sampleBuffer)
            }
        }
    }

    /// Apply crossfade between two sample arrays to eliminate clicks at boundaries
    private func applyCrossfade(from previous: [Float], to current: inout [Float]) {
        let fadeLength = min(crossfadeLength, previous.count, current.count)
        guard fadeLength > 0 else { return }

        for i in 0..<fadeLength {
            let fadeOut = Float(fadeLength - i) / Float(fadeLength)
            let fadeIn = Float(i) / Float(fadeLength)
            let prevIndex = previous.count - fadeLength + i
            current[i] = previous[prevIndex] * fadeOut + current[i] * fadeIn
        }
    }

    private func createOutputSampleBuffer(from samples: [Float]) -> CMSampleBuffer? {
        guard let formatDescription = outputFormatDescription else { return nil }

        let frameCount = samples.count
        let dataSize = frameCount * MemoryLayout<Float>.size

        // Create block buffer
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

        // Copy data
        status = samples.withUnsafeBufferPointer { bufferPointer in
            CMBlockBufferReplaceDataBytes(
                with: bufferPointer.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }

        guard status == kCMBlockBufferNoErr else { return nil }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let presentationTime = CMTime(value: outputSampleTime, timescale: CMTimeScale(sampleRate))

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

        outputSampleTime += Int64(frameCount)

        return sampleBuffer
    }

    /// Flush remaining samples in buffers
    func flush() {
        processingQueue.sync { [weak self] in
            guard let self = self else { return }

            // Process any remaining samples - use the smaller of the two to avoid padding
            let remaining = min(self.systemBuffer.count, self.micBuffer.count)
            if remaining > 0 {
                var mixedSamples = [Float](repeating: 0, count: remaining)

                let systemSamples = Array(self.systemBuffer.prefix(remaining))
                let micSamples = Array(self.micBuffer.prefix(remaining))

                vDSP_vadd(mixedSamples, 1, systemSamples, 1, &mixedSamples, 1, vDSP_Length(remaining))
                vDSP_vadd(mixedSamples, 1, micSamples, 1, &mixedSamples, 1, vDSP_Length(remaining))

                // Apply crossfade from previous buffer
                if !self.previousOutputTail.isEmpty {
                    self.applyCrossfade(from: self.previousOutputTail, to: &mixedSamples)
                }

                var minVal: Float = -1.0
                var maxVal: Float = 1.0
                vDSP_vclip(mixedSamples, 1, &minVal, &maxVal, &mixedSamples, 1, vDSP_Length(remaining))

                if let sampleBuffer = self.createOutputSampleBuffer(from: mixedSamples) {
                    self.outputHandler?(sampleBuffer)
                }
            }

            // Reset state for next recording
            self.systemBuffer.removeAll()
            self.micBuffer.removeAll()
            self.previousOutputTail.removeAll()
            self.startupComplete = false
            self.outputSampleTime = 0
        }
    }
}

enum AudioMixerError: Error, LocalizedError {
    case failedToCreateFormat

    var errorDescription: String? {
        switch self {
        case .failedToCreateFormat:
            return "Failed to create audio format for mixer"
        }
    }
}
