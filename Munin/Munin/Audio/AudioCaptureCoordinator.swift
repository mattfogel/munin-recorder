import Foundation
import ScreenCaptureKit
import AVFoundation

@MainActor
final class AudioCaptureCoordinator {
    private var systemCapture: SystemAudioCapture?
    private var fileWriter: AudioFileWriter?
    private var outputURL: URL?

    func startCapture(outputURL: URL) async throws {
        self.outputURL = outputURL

        // Initialize file writer
        fileWriter = try AudioFileWriter(outputURL: outputURL)
        try fileWriter?.startWriting()

        // Initialize and start system audio capture (includes mic via captureMicrophone)
        systemCapture = try await SystemAudioCapture { [weak self] sampleBuffer in
            self?.fileWriter?.appendSampleBuffer(sampleBuffer)
        }

        try await systemCapture?.startCapture()
    }

    func stopCapture() async {
        await systemCapture?.stopCapture()
        await fileWriter?.finishWriting()

        systemCapture = nil
        fileWriter = nil
    }
}
