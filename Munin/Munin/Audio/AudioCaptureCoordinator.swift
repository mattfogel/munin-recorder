import Foundation
import AVFoundation

@MainActor
final class AudioCaptureCoordinator {
    private var systemCapture: SystemAudioCapture?
    private var audioMixer: AudioMixer?
    private var fileWriter: AudioFileWriter?
    private var outputURL: URL?

    func startCapture(outputURL: URL) async throws {
        self.outputURL = outputURL

        // Initialize file writer
        fileWriter = try AudioFileWriter(outputURL: outputURL)
        try fileWriter?.startWriting()

        // Initialize audio mixer
        audioMixer = try AudioMixer()
        audioMixer?.outputHandler = { [weak self] sampleBuffer in
            self?.fileWriter?.appendSampleBuffer(sampleBuffer)
        }

        // Initialize and start system audio capture with separate handlers
        systemCapture = try await SystemAudioCapture(
            systemAudioHandler: { [weak self] sampleBuffer in
                self?.audioMixer?.appendSystemAudio(sampleBuffer)
            },
            microphoneHandler: { [weak self] sampleBuffer in
                self?.audioMixer?.appendMicrophoneAudio(sampleBuffer)
            }
        )

        try await systemCapture?.startCapture()
    }

    func stopCapture() async {
        await systemCapture?.stopCapture()
        audioMixer?.flush()
        await fileWriter?.finishWriting()

        systemCapture = nil
        audioMixer = nil
        fileWriter = nil
    }
}
