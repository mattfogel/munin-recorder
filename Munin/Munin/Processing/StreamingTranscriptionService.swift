import Foundation
import Speech
import AVFoundation
import CoreMedia

/// A timestamped transcript segment from streaming transcription
struct TranscriptSegment: Comparable, Sendable {
    let startMs: Int
    let endMs: Int
    let speaker: String  // "Me" or "Them"
    let text: String
    let isFinal: Bool

    static func < (lhs: TranscriptSegment, rhs: TranscriptSegment) -> Bool {
        lhs.startMs < rhs.startMs
    }
}

/// Manages one SpeechAnalyzer + SpeechTranscriber pair for a single audio channel.
/// Create two instances (mic + system) for diarized transcription.
final class StreamingTranscriptionService: @unchecked Sendable {
    enum TranscriptionError: Error, LocalizedError {
        case modelNotAvailable
        case localeNotSupported
        case analyzerStartFailed(Error)
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .modelNotAvailable:
                return "Speech recognition model not available"
            case .localeNotSupported:
                return "Current locale not supported for speech recognition"
            case .analyzerStartFailed(let error):
                return "Failed to start speech analyzer: \(error.localizedDescription)"
            case .permissionDenied:
                return "Speech recognition permission denied"
            }
        }
    }

    let speaker: String
    private let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var audioConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    // Source format: 48kHz mono float32 (from AudioMixer pre-interleave tap)
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 1,
        interleaved: false
    )!

    // Accumulated final segments
    private var finalSegments: [TranscriptSegment] = []
    private var latestVolatileSegment: TranscriptSegment?
    private let segmentsLock = NSLock()

    // Progressive file writing
    private var transcriptURL: URL?
    private var lastFlushTime: CFAbsoluteTime = 0
    private let flushInterval: CFAbsoluteTime = 10.0

    // Result consumption task
    private var resultTask: Task<Void, Never>?

    // Segment callback for live updates
    var onSegment: ((TranscriptSegment) -> Void)?

    init(speaker: String, locale: Locale = .current) {
        self.speaker = speaker
        self.locale = locale
    }

    /// Check if the speech recognition model is installed for the current locale
    static func isModelInstalled(locale: Locale = .current) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains(locale)
    }

    /// Download the speech recognition model if not already installed.
    /// Returns true if model is ready (already installed or download succeeded).
    static func ensureModelAvailable(locale: Locale = .current) async throws -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(locale) {
            return true
        }

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(locale) else {
            throw TranscriptionError.localeNotSupported
        }

        // Create a temporary transcriber to trigger model download
        let tempTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [tempTranscriber]) {
            try await request.downloadAndInstall()
        }

        return true
    }

    /// Start the analyzer and begin accepting audio samples.
    /// Call feedSamples() to provide audio data, then finalize() when recording stops.
    func start(transcriptURL: URL? = nil) async throws {
        self.transcriptURL = transcriptURL

        let newTranscriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])

        // Get the best audio format for the analyzer
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [newTranscriber])
        analyzerFormat = format

        // Create converter from 48kHz mono float32 → analyzer format
        if let format, sourceFormat != format {
            audioConverter = AVAudioConverter(from: sourceFormat, to: format)
        }

        // Create the input stream
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        self.transcriber = newTranscriber
        self.analyzer = newAnalyzer

        // Start consuming results in background
        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in newTranscriber.results {
                    self.handleResult(result)
                }
            } catch {
                debugLog("[\(self.speaker)] Result stream error: \(error)")
            }
        }

        // Start the analyzer with input sequence
        do {
            try await newAnalyzer.start(inputSequence: inputSequence)
        } catch {
            inputContinuation?.finish()
            resultTask?.cancel()
            throw TranscriptionError.analyzerStartFailed(error)
        }
    }

    /// Feed raw float32 mono samples from AudioMixer pre-interleave tap.
    /// Called on AudioMixer's processing queue.
    func feedSamples(_ samples: [Float]) {
        guard let continuation = inputContinuation,
              let targetFormat = analyzerFormat else { return }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return }
        sourceBuffer.frameLength = frameCount

        // Copy samples into source buffer
        guard let channelData = sourceBuffer.floatChannelData else { return }
        _ = samples.withUnsafeBufferPointer { ptr in
            memcpy(channelData[0], ptr.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }

        // Convert to analyzer format if needed
        let outputBuffer: AVAudioPCMBuffer
        if let converter = audioConverter {
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

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

            converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
            if error != nil { return }
            outputBuffer = converted
        } else {
            outputBuffer = sourceBuffer
        }

        continuation.yield(AnalyzerInput(buffer: outputBuffer))
    }

    /// Finalize transcription after recording stops.
    /// Waits for remaining results up to the timeout.
    func finalize(timeout: TimeInterval = 30) async -> [TranscriptSegment] {
        // Signal end of input
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            debugLog("[\(speaker)] Finalization error: \(error)")
        }
        inputContinuation?.finish()

        // Wait for result task to complete with timeout
        let deadline = Task {
            try await Task.sleep(for: .seconds(timeout))
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.resultTask?.value
            }
            group.addTask {
                try? await deadline.value
            }
            // Wait for whichever finishes first
            await group.next()
            group.cancelAll()
        }

        resultTask?.cancel()

        // Flush final segments to disk
        flushToDisk(force: true)

        return copyFinalSegments()
    }

    /// Cancel transcription immediately without waiting for remaining results
    func cancel() {
        Task {
            await analyzer?.cancelAndFinishNow()
        }
        inputContinuation?.finish()
        resultTask?.cancel()
    }

    // MARK: - Private

    /// Thread-safe copy of final segments (avoids NSLock in async context)
    private nonisolated func copyFinalSegments() -> [TranscriptSegment] {
        segmentsLock.lock()
        let result = finalSegments
        segmentsLock.unlock()
        return result
    }

    private func handleResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Extract timestamp from the first run's audioTimeRange
        var startMs = 0
        var endMs = 0
        for run in result.text.runs {
            if let timeRange = run.audioTimeRange {
                let startSeconds = CMTimeGetSeconds(timeRange.start)
                let endSeconds = CMTimeGetSeconds(timeRange.start) + CMTimeGetSeconds(timeRange.duration)
                if startMs == 0 || Int(startSeconds * 1000) < startMs {
                    startMs = Int(startSeconds * 1000)
                }
                endMs = max(endMs, Int(endSeconds * 1000))
            }
        }

        let segment = TranscriptSegment(
            startMs: startMs,
            endMs: endMs,
            speaker: speaker,
            text: text,
            isFinal: result.isFinal
        )

        if result.isFinal {
            segmentsLock.lock()
            finalSegments.append(segment)
            latestVolatileSegment = nil
            segmentsLock.unlock()

            // Periodically flush to disk
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastFlushTime >= flushInterval {
                flushToDisk(force: false)
                lastFlushTime = now
            }
        } else {
            segmentsLock.lock()
            latestVolatileSegment = segment
            segmentsLock.unlock()
        }

        onSegment?(segment)
    }

    private func flushToDisk(force: Bool) {
        guard let url = transcriptURL else { return }

        segmentsLock.lock()
        let segments = finalSegments
        segmentsLock.unlock()

        guard !segments.isEmpty else { return }

        // Write atomically via temp file
        let content = Self.formatTranscript(segments: segments, speaker: speaker)
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".transcript_\(speaker)_tmp.md")
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            try FileManager.default.moveItem(at: tempURL, to: url)
        } catch {
            // Fallback: write directly
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Format segments into a simple per-channel transcript fragment
    static func formatTranscript(segments: [TranscriptSegment], speaker: String) -> String {
        var lines: [String] = []
        for segment in segments {
            let timestamp = formatTimestamp(segment.startMs)
            lines.append("[\(timestamp)] \(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Merge two channels' segments by timestamp and format as diarized markdown
    static func formatDiarizedTranscript(
        micSegments: [TranscriptSegment],
        systemSegments: [TranscriptSegment],
        participants: [String] = []
    ) -> String {
        var merged = micSegments + systemSegments
        merged.sort()

        var lines: [String] = ["# Transcript", ""]

        if !participants.isEmpty {
            lines.append("**Participants:** \(participants.joined(separator: ", "))")
            lines.append("")
        }

        let gapThresholdMs = 1500
        var currentSpeaker = ""
        var previousEndMs: Int? = nil

        for segment in merged {
            let gapMs: Int
            if let prev = previousEndMs {
                gapMs = max(0, segment.startMs - prev)
            } else {
                gapMs = 0
            }

            if segment.speaker != currentSpeaker || gapMs >= gapThresholdMs {
                if !currentSpeaker.isEmpty {
                    lines.append("")
                }
                currentSpeaker = segment.speaker
                lines.append("**\(segment.speaker):**")
            }

            let timestamp = formatTimestamp(segment.startMs)
            lines.append("[\(timestamp)] \(segment.text)")
            previousEndMs = segment.endMs
        }

        return lines.joined(separator: "\n")
    }

    /// Format milliseconds into "HH:MM:SS.mmm"
    static func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let millis = max(0, ms) % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
    }
}
