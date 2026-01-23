import Foundation
import ScreenCaptureKit
import CoreMedia

final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private let audioHandler: (CMSampleBuffer) -> Void

    init(audioHandler: @escaping (CMSampleBuffer) -> Void) async throws {
        self.audioHandler = audioHandler
        super.init()

        // Get available content
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        // Create filter for full display capture (we only want audio, but need a display)
        filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream for audio capture with microphone (macOS 15+)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true  // macOS 15+ - captures mic in same stream
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1

        // Minimize video overhead
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2

        stream = SCStream(filter: filter!, configuration: config, delegate: self)
    }

    func startCapture() async throws {
        guard let stream = stream else {
            throw AudioCaptureError.streamNotInitialized
        }

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.munin.audio"))
        try await stream.startCapture()
    }

    func stopCapture() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        audioHandler(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case noDisplayFound
    case streamNotInitialized

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for screen capture"
        case .streamNotInitialized:
            return "Audio stream not initialized"
        }
    }
}
