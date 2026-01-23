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

        let audioQueue = DispatchQueue(label: "com.munin.audio")
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        // macOS 15+: microphone audio comes through separate output type
        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }

        try await stream.startCapture()
        print("Munin: Audio capture started")
    }

    func stopCapture() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    private var audioSampleCount = 0
    private var micSampleCount = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Handle both system audio and microphone audio (macOS 15+)
        switch type {
        case .audio:
            audioSampleCount += 1
            if audioSampleCount % 100 == 1 {
                print("Munin: System audio samples received: \(audioSampleCount)")
            }
            audioHandler(sampleBuffer)
        case .microphone:
            micSampleCount += 1
            if micSampleCount % 100 == 1 {
                print("Munin: Microphone samples received: \(micSampleCount)")
            }
            audioHandler(sampleBuffer)
        default:
            break
        }
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
