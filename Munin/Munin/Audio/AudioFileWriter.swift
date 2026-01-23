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
