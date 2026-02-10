import Foundation
import AVFoundation
import CoreAudio
import CoreMedia
import Accelerate

/// Soft limiter with fast attack, slow release to prevent clipping without distortion
private final class SoftLimiter {
    private let threshold: Float = 0.5  // -6dB
    private let knee: Float = 0.2       // Soft transition range
    private let ratio: Float = 8.0      // 8:1 compression above threshold
    private var envelope: Float = 0     // Peak follower

    // Attack/release coefficients for 48kHz
    // Attack: ~2ms = 96 samples, coef ≈ 1 - exp(-1/96) ≈ 0.01
    // Release: ~50ms = 2400 samples, coef ≈ 1 - exp(-1/2400) ≈ 0.0004
    private let attackCoef: Float = 0.01
    private let releaseCoef: Float = 0.0004

    func process(_ samples: inout [Float]) {
        for i in samples.indices {
            let absVal = abs(samples[i])

            // Peak follower with fast attack, slow release
            if absVal > envelope {
                envelope = attackCoef * absVal + (1 - attackCoef) * envelope
            } else {
                envelope = releaseCoef * absVal + (1 - releaseCoef) * envelope
            }

            // Soft knee gain reduction
            let kneeStart = threshold - knee / 2
            let kneeEnd = threshold + knee / 2

            if envelope > kneeStart {
                let gain: Float
                if envelope < kneeEnd {
                    // In the knee region - smooth transition
                    let kneeProgress = (envelope - kneeStart) / knee
                    let compressionAmount = kneeProgress * kneeProgress / 2
                    let overshoot = envelope - threshold
                    let reduction = overshoot * (1 - 1 / ratio) * compressionAmount
                    gain = (envelope - reduction) / envelope
                } else {
                    // Above knee - full compression
                    let overshoot = envelope - threshold
                    let compressed = threshold + overshoot / ratio
                    gain = compressed / envelope
                }
                samples[i] *= gain
            }
        }
    }

    func reset() {
        envelope = 0
    }
}

/// Audio level data for VU meters
struct AudioMixerLevels: Sendable {
    let micLevel: Float
    let systemLevel: Float
}

/// Outputs stereo audio: Left = Mic, Right = System for diarization
final class AudioMixer: @unchecked Sendable {
    // Output format: 48kHz stereo float32
    private let sampleRate: Double = 48000
    private let channelCount: UInt32 = 2

    // Unity gain - soft limiter handles levels
    private let systemAudioGain: Float = 1.0
    private let microphoneGain: Float = 1.0

    // Soft limiters (one per channel)
    private let micLimiter = SoftLimiter()
    private let systemLimiter = SoftLimiter()

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
    private var baseHostTime: UInt64?
    private let hostClockFrequency: Double = {
        let frequency = AudioGetHostClockFrequency()
        return frequency > 0 ? frequency : 1
    }()
    private let maxTimestampJitterSamples: Int64 = 128
    private var systemExpectedSampleTime: Int64 = 0
    private var micExpectedSampleTime: Int64 = 0

    // Previous output for crossfading between buffers
    private var previousOutputTail: [Float] = []

    // Output
    var outputHandler: ((CMSampleBuffer) -> Void)?

    /// Pre-interleave tap: fires with per-channel mono float32 samples before stereo interleaving.
    /// Parameters: (micSamples, systemSamples) — both at 48kHz mono.
    var preInterleaveTapHandler: (([Float], [Float]) -> Void)?

    // Audio level monitoring (for VU meters)
    var levelHandler: ((AudioMixerLevels) -> Void)?
    private var lastLevelUpdate: CFAbsoluteTime = 0
    private let levelUpdateInterval: CFAbsoluteTime = 0.067 // ~15 Hz

    // Format descriptions cached for efficiency
    private var outputFormatDescription: CMAudioFormatDescription?
    private var systemAudioConverter: AVAudioConverter?
    private var microphoneConverter: AVAudioConverter?
    private lazy var outputFormat: AVAudioFormat = {
        // Mono format for input conversion (before stereo interleaving)
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }()

    init() throws {
        // Create output format description - stereo interleaved float32
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,  // 2 channels × 4 bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,   // 2 channels × 4 bytes
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
            self?.appendToBuffer(sampleBuffer, hostTime: nil, isSystem: true)
        }
    }

    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer, hostTime: UInt64) {
        processingQueue.async { [weak self] in
            self?.appendToBuffer(sampleBuffer, hostTime: hostTime, isSystem: true)
        }
    }

    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self] in
            self?.appendToBuffer(sampleBuffer, hostTime: nil, isMicrophone: true)
        }
    }

    func appendMicrophoneAudio(_ sampleBuffer: CMSampleBuffer, hostTime: UInt64) {
        processingQueue.async { [weak self] in
            self?.appendToBuffer(sampleBuffer, hostTime: hostTime, isMicrophone: true)
        }
    }

    func setBaseHostTime(_ hostTime: UInt64) {
        processingQueue.sync { [weak self] in
            self?.baseHostTime = hostTime
        }
    }

    private func appendToBuffer(_ sampleBuffer: CMSampleBuffer, hostTime: UInt64?, isSystem: Bool = false, isMicrophone: Bool = false) {
        guard let samples = extractFloatSamples(from: sampleBuffer, isSystem: isSystem, isMicrophone: isMicrophone) else {
            return
        }

        let bufferStartSampleTime: Int64
        if let hostTime = hostTime {
            bufferStartSampleTime = sampleTimeFromHostTime(hostTime)
        } else {
            bufferStartSampleTime = isSystem ? systemExpectedSampleTime : micExpectedSampleTime
        }
        if isSystem {
            appendAlignedSamples(
                samples,
                to: &systemBuffer,
                expectedSampleTime: &systemExpectedSampleTime,
                startSampleTime: bufferStartSampleTime
            )
        } else if isMicrophone {
            appendAlignedSamples(
                samples,
                to: &micBuffer,
                expectedSampleTime: &micExpectedSampleTime,
                startSampleTime: bufferStartSampleTime
            )
        }

        // Process when we have enough samples from both sources
        processBuffers()
    }

    private func sampleTimeFromHostTime(_ hostTime: UInt64) -> Int64 {
        if baseHostTime == nil {
            baseHostTime = hostTime
        }
        guard let base = baseHostTime else { return 0 }
        let delta = hostTime >= base ? hostTime - base : 0
        let seconds = Double(delta) / hostClockFrequency
        return Int64((seconds * sampleRate).rounded())
    }

    private func appendAlignedSamples(
        _ samples: [Float],
        to buffer: inout [Float],
        expectedSampleTime: inout Int64,
        startSampleTime: Int64
    ) {
        var alignedSamples = samples
        var delta = startSampleTime - expectedSampleTime

        if delta < 0, abs(delta) <= maxTimestampJitterSamples {
            delta = 0
        }

        if delta > 0 {
            buffer.append(contentsOf: [Float](repeating: 0, count: Int(delta)))
            expectedSampleTime += delta
        } else if delta < 0 {
            let overlap = min(Int(-delta), alignedSamples.count)
            if overlap >= alignedSamples.count {
                return
            }
            alignedSamples.removeFirst(overlap)
        }

        buffer.append(contentsOf: alignedSamples)
        expectedSampleTime += Int64(alignedSamples.count)
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

        // Check if we need conversion (input is mono, output is stereo interleaved later)
        let needsConversion = sourceFormat.sampleRate != sampleRate ||
                             sourceFormat.channelCount != 1 ||
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

        // Process only when BOTH sources have enough data
        // This prevents silence padding which causes discontinuities
        while systemBuffer.count >= bufferSize && micBuffer.count >= bufferSize {
            // Extract exactly bufferSize samples from each source
            var systemSamples = Array(systemBuffer.prefix(bufferSize))
            systemBuffer.removeFirst(bufferSize)

            var micSamples = Array(micBuffer.prefix(bufferSize))
            micBuffer.removeFirst(bufferSize)

            // Pre-interleave tap: deliver raw mono samples for streaming transcription
            preInterleaveTapHandler?(micSamples, systemSamples)

            // Calculate and report audio levels (throttled to ~15 Hz)
            updateAudioLevels(micSamples: micSamples, systemSamples: systemSamples)

            // Apply soft limiting per channel (prevents clipping without distortion)
            micLimiter.process(&micSamples)
            systemLimiter.process(&systemSamples)

            // Interleave to stereo: Left = Mic, Right = System
            var stereoSamples = [Float](repeating: 0, count: bufferSize * 2)
            for i in 0..<bufferSize {
                stereoSamples[i * 2] = micSamples[i]       // Left channel
                stereoSamples[i * 2 + 1] = systemSamples[i] // Right channel
            }

            // Apply crossfade from previous buffer to smooth transitions
            if !previousOutputTail.isEmpty {
                applyCrossfade(from: previousOutputTail, to: &stereoSamples)
            }

            // Save tail for next crossfade (stereo samples)
            previousOutputTail = Array(stereoSamples.suffix(crossfadeLength * 2))

            // Create output sample buffer
            if let sampleBuffer = createOutputSampleBuffer(from: stereoSamples) {
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

        // For stereo, frame count is sample count / 2
        let frameCount = samples.count / Int(channelCount)
        let dataSize = samples.count * MemoryLayout<Float>.size

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

    /// Calculate RMS level and update handler (throttled)
    private func updateAudioLevels(micSamples: [Float], systemSamples: [Float]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelUpdate >= levelUpdateInterval else { return }
        lastLevelUpdate = now

        let micLevel = calculateRMSLevel(samples: micSamples)
        let systemLevel = calculateRMSLevel(samples: systemSamples)

        let levels = AudioMixerLevels(micLevel: micLevel, systemLevel: systemLevel)
        levelHandler?(levels)
    }

    /// Calculate RMS level (0.0 to 1.0) from audio samples
    private func calculateRMSLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        // Calculate RMS using Accelerate
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

        // Convert to dB and normalize to 0-1 range
        // -60 dB = silence, 0 dB = full scale
        let db = 20 * log10(max(rms, 1e-10))
        let normalized = (db + 60) / 60 // Map -60..0 dB to 0..1
        return max(0, min(1, normalized))
    }

    /// Flush remaining samples in buffers
    func flush() {
        processingQueue.sync { [weak self] in
            guard let self = self else { return }

            // Process any remaining samples - use the smaller of the two to avoid padding
            let remaining = min(self.systemBuffer.count, self.micBuffer.count)
            if remaining > 0 {
                var systemSamples = Array(self.systemBuffer.prefix(remaining))
                var micSamples = Array(self.micBuffer.prefix(remaining))

                // Pre-interleave tap: deliver remaining samples for streaming transcription
                self.preInterleaveTapHandler?(micSamples, systemSamples)

                // Apply soft limiting
                self.micLimiter.process(&micSamples)
                self.systemLimiter.process(&systemSamples)

                // Interleave to stereo: Left = Mic, Right = System
                var stereoSamples = [Float](repeating: 0, count: remaining * 2)
                for i in 0..<remaining {
                    stereoSamples[i * 2] = micSamples[i]
                    stereoSamples[i * 2 + 1] = systemSamples[i]
                }

                // Apply crossfade from previous buffer
                if !self.previousOutputTail.isEmpty {
                    self.applyCrossfade(from: self.previousOutputTail, to: &stereoSamples)
                }

                if let sampleBuffer = self.createOutputSampleBuffer(from: stereoSamples) {
                    self.outputHandler?(sampleBuffer)
                }
            }

            // Reset state for next recording
            self.systemBuffer.removeAll()
            self.micBuffer.removeAll()
            self.previousOutputTail.removeAll()
            self.startupComplete = false
            self.outputSampleTime = 0
            self.lastLevelUpdate = 0
            self.baseHostTime = nil
            self.systemExpectedSampleTime = 0
            self.micExpectedSampleTime = 0
            self.micLimiter.reset()
            self.systemLimiter.reset()
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
