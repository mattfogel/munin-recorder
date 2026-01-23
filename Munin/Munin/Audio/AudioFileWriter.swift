import Foundation
import AVFoundation
import CoreMedia

final class AudioFileWriter: @unchecked Sendable {
    private let outputURL: URL
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var isWriting = false
    private let writingQueue = DispatchQueue(label: "com.munin.audiowriter")

    init(outputURL: URL) throws {
        self.outputURL = outputURL

        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        // AAC audio settings
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true

        if let audioInput = audioInput, assetWriter?.canAdd(audioInput) == true {
            assetWriter?.add(audioInput)
        }
    }

    func startWriting() throws {
        guard assetWriter?.startWriting() == true else {
            throw AudioWriterError.failedToStart
        }
        assetWriter?.startSession(atSourceTime: .zero)
        isWriting = true
    }

    func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.async { [weak self] in
            guard let self = self,
                  self.isWriting,
                  let audioInput = self.audioInput,
                  audioInput.isReadyForMoreMediaData else {
                return
            }

            audioInput.append(sampleBuffer)
        }
    }

    private var sampleTime: CMTime = .zero
    private var sessionStarted = false

    func appendPCMBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        writingQueue.async { [weak self] in
            guard let self = self,
                  self.isWriting,
                  let audioInput = self.audioInput,
                  audioInput.isReadyForMoreMediaData else {
                return
            }

            // Convert AVAudioPCMBuffer to CMSampleBuffer
            guard let sampleBuffer = self.createSampleBuffer(from: buffer) else {
                return
            }

            audioInput.append(sampleBuffer)
        }
    }

    private func createSampleBuffer(from pcmBuffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let frameCount = pcmBuffer.frameLength
        guard frameCount > 0 else { return nil }

        let format = pcmBuffer.format
        var formatDescription: CMAudioFormatDescription?

        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDesc = formatDescription else {
            return nil
        }

        // Calculate timing
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(format.sampleRate))
        let duration = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        let presentationTime = sampleTime

        // Update sample time for next buffer
        sampleTime = CMTimeAdd(sampleTime, duration)

        // Create block buffer from PCM data
        var blockBuffer: CMBlockBuffer?
        let audioDataSize = Int(frameCount) * Int(format.streamDescription.pointee.mBytesPerFrame)

        guard let floatData = pcmBuffer.floatChannelData?[0] else {
            return nil
        }

        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: audioDataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: audioDataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard blockStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            return nil
        }

        // Copy audio data to block buffer
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: floatData,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: audioDataSize
        )

        guard copyStatus == kCMBlockBufferNoErr else {
            return nil
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr else {
            return nil
        }

        return sampleBuffer
    }

    func finishWriting() async {
        isWriting = false

        await withCheckedContinuation { continuation in
            writingQueue.async { [weak self] in
                self?.audioInput?.markAsFinished()
                self?.assetWriter?.finishWriting {
                    continuation.resume()
                }
            }
        }
    }
}

enum AudioWriterError: Error, LocalizedError {
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .failedToStart:
            return "Failed to start audio file writer"
        }
    }
}
