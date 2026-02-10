import Foundation
import AVFoundation
import CoreAudio

@MainActor
final class AudioCaptureCoordinator {
    private var systemCapture: SystemAudioCapture?
    private var audioMixer: AudioMixer?
    private var fileWriter: AudioFileWriter?
    private var outputURL: URL?

    // Streaming transcription services (one per channel)
    private var micTranscriber: StreamingTranscriptionService?
    private var systemTranscriber: StreamingTranscriptionService?

    /// Callback for audio level updates (for VU meters)
    var levelHandler: ((AudioMixerLevels) -> Void)?

    /// Callback for live transcript segments
    var onTranscriptSegment: ((TranscriptSegment) -> Void)?

    func startCapture(outputURL: URL, transcriptURL: URL?) async throws {
        self.outputURL = outputURL

        // Initialize file writer
        fileWriter = try AudioFileWriter(outputURL: outputURL)
        try fileWriter?.startWriting()

        // Initialize streaming transcription services
        let mic = StreamingTranscriptionService(speaker: "Me")
        let system = StreamingTranscriptionService(speaker: "Them")

        mic.onSegment = { [weak self] segment in
            Task { @MainActor in self?.onTranscriptSegment?(segment) }
        }
        system.onSegment = { [weak self] segment in
            Task { @MainActor in self?.onTranscriptSegment?(segment) }
        }

        micTranscriber = mic
        systemTranscriber = system

        // Start both analyzers
        try await mic.start()
        try await system.start()

        // Initialize audio mixer
        audioMixer = try AudioMixer()
        audioMixer?.outputHandler = { [weak self] sampleBuffer in
            self?.fileWriter?.appendSampleBuffer(sampleBuffer)
        }
        audioMixer?.levelHandler = { [weak self] levels in
            self?.levelHandler?(levels)
        }
        audioMixer?.preInterleaveTapHandler = { [weak mic, weak system] micSamples, systemSamples in
            mic?.feedSamples(micSamples)
            system?.feedSamples(systemSamples)
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

    /// Stop capture, finalize transcription, and return the merged transcript.
    func stopCapture(participants: [String] = []) async -> String? {
        await systemCapture?.stopCapture()
        audioMixer?.flush()
        await fileWriter?.finishWriting()

        // Finalize both transcribers and merge results
        var transcript: String? = nil
        if let mic = micTranscriber, let system = systemTranscriber {
            debugLog("Finalizing both transcribers...")
            async let micSegments = mic.finalize()
            async let systemSegments = system.finalize()
            let (micResult, systemResult) = await (micSegments, systemSegments)
            debugLog("Transcription results — mic: \(micResult.count) segments, system: \(systemResult.count) segments")

            if !micResult.isEmpty || !systemResult.isEmpty {
                transcript = StreamingTranscriptionService.formatDiarizedTranscript(
                    micSegments: micResult,
                    systemSegments: systemResult,
                    participants: participants
                )
                debugLog("Merged transcript: \(transcript?.count ?? 0) characters")
            } else {
                debugLog("No transcript segments from either channel")
            }
        }

        systemCapture = nil
        audioMixer = nil
        fileWriter = nil
        micTranscriber = nil
        systemTranscriber = nil

        return transcript
    }
}
