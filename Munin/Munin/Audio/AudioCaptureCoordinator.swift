import Foundation
import AVFoundation
import CoreAudio

@MainActor
final class AudioCaptureCoordinator {
    private var systemCapture: SystemAudioCapture?
    private var audioMixer: AudioMixer?
    private var fileWriter: AudioFileWriter?
    private var outputURL: URL?

    /// Callback for audio level updates (for VU meters)
    var levelHandler: ((AudioMixerLevels) -> Void)?

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
        audioMixer?.levelHandler = { [weak self] levels in
            self?.levelHandler?(levels)
        }
        // Initialize and start system audio capture with separate handlers
        systemCapture = try await SystemAudioCapture(
            systemAudioHandler: { [weak self] sampleBuffer, hostTime in
                self?.audioMixer?.appendSystemAudio(sampleBuffer, hostTime: hostTime)
            },
            microphoneHandler: { [weak self] sampleBuffer, hostTime in
                self?.audioMixer?.appendMicrophoneAudio(sampleBuffer, hostTime: hostTime)
            }
        )

        audioMixer?.setBaseHostTime(AudioGetCurrentHostTime())
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
