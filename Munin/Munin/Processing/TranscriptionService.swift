import Foundation

/// Represents a timestamped segment from whisper transcription
private struct TranscriptSegment: Comparable {
    let startMs: Int
    let endMs: Int
    let speaker: String  // "Me" or "Them"
    let text: String

    static func < (lhs: TranscriptSegment, rhs: TranscriptSegment) -> Bool {
        lhs.startMs < rhs.startMs
    }
}

final class TranscriptionService {
    enum TranscriptionError: Error, LocalizedError {
        case whisperNotFound
        case modelNotFound
        case conversionFailed
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .whisperNotFound:
                return "whisper.cpp not found. Please install it and ensure it's in your PATH."
            case .modelNotFound:
                return "Whisper model not found. Please download a model to ~/.munin/models/"
            case .conversionFailed:
                return "Failed to convert audio to WAV format"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            }
        }
    }

    private let whisperPath: String?
    private let modelPath: String?

    init() {
        // Try to find whisper binary - prefer whisper-cli (main is deprecated)
        self.whisperPath = ProcessRunner.findExecutable(
            name: "whisper-cli",
            additionalPaths: [
                NSHomeDirectory() + "/.munin/whisper.cpp/whisper-cli",
                "/opt/homebrew/bin/whisper-cli",
                "/usr/local/bin/whisper-cli"
            ]
        ) ?? ProcessRunner.findExecutable(
            name: "whisper",
            additionalPaths: [
                NSHomeDirectory() + "/.munin/whisper.cpp/whisper",
                "/opt/homebrew/bin/whisper",
                "/usr/local/bin/whisper"
            ]
        )

        // Try to find model
        self.modelPath = Self.findModel()
    }

    func transcribe(audioURL: URL, outputURL: URL, participants: [String] = []) async throws {
        guard let whisperPath = whisperPath else {
            throw TranscriptionError.whisperNotFound
        }

        guard let modelPath = modelPath else {
            throw TranscriptionError.modelNotFound
        }

        let baseDir = audioURL.deletingLastPathComponent()
        let micWavURL = baseDir.appendingPathComponent("mic.wav")
        let systemWavURL = baseDir.appendingPathComponent("system.wav")

        // Split stereo m4a into separate mono wav files (L=mic, R=system)
        try await splitStereoToMono(inputURL: audioURL, micURL: micWavURL, systemURL: systemWavURL)

        // Transcribe both channels with timestamps
        async let micVtt = transcribeChannel(whisperPath: whisperPath, modelPath: modelPath, wavURL: micWavURL, speaker: "Me")
        async let systemVtt = transcribeChannel(whisperPath: whisperPath, modelPath: modelPath, wavURL: systemWavURL, speaker: "Them")

        let (micSegments, systemSegments) = try await (micVtt, systemVtt)

        // Merge and format transcript
        let merged = mergeTranscripts(mic: micSegments, system: systemSegments)
        try formatDiarizedTranscript(segments: merged, outputURL: outputURL, participants: participants)

        // Clean up temp files
        try? FileManager.default.removeItem(at: micWavURL)
        try? FileManager.default.removeItem(at: systemWavURL)
    }

    /// Split stereo m4a into two mono wav files using afconvert
    /// Two-step process: m4a → stereo wav → split channels (afconvert crashes on direct AAC channel extraction)
    private func splitStereoToMono(inputURL: URL, micURL: URL, systemURL: URL) async throws {
        let afconvertPath = "/usr/bin/afconvert"
        let stereoWavURL = inputURL.deletingLastPathComponent().appendingPathComponent("stereo_temp.wav")

        // Step 1: Convert m4a to stereo wav at 16kHz
        let stereoResult = try await ProcessRunner.run(
            executablePath: afconvertPath,
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                inputURL.path,
                stereoWavURL.path
            ],
            timeout: 300
        )

        if !stereoResult.success {
            throw TranscriptionError.conversionFailed
        }

        defer { try? FileManager.default.removeItem(at: stereoWavURL) }

        // Step 2: Extract left channel (mic) from stereo wav
        let micResult = try await ProcessRunner.run(
            executablePath: afconvertPath,
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1",
                "-m", "0",
                stereoWavURL.path,
                micURL.path
            ],
            timeout: 300
        )

        if !micResult.success {
            throw TranscriptionError.conversionFailed
        }

        // Step 3: Extract right channel (system) from stereo wav
        let systemResult = try await ProcessRunner.run(
            executablePath: afconvertPath,
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                "-c", "1",
                "-m", "1",
                stereoWavURL.path,
                systemURL.path
            ],
            timeout: 300
        )

        if !systemResult.success {
            throw TranscriptionError.conversionFailed
        }
    }

    /// Transcribe a single channel and return parsed segments
    private func transcribeChannel(
        whisperPath: String,
        modelPath: String,
        wavURL: URL,
        speaker: String
    ) async throws -> [TranscriptSegment] {
        let outputBase = wavURL.deletingPathExtension()

        // Run whisper with VTT output for timestamps
        let result = try await ProcessRunner.run(
            executablePath: whisperPath,
            arguments: [
                "-m", modelPath,
                "-f", wavURL.path,
                "-ovtt",  // VTT format has timestamps
                "-of", outputBase.path,
                "--print-progress"
            ],
            timeout: 1800
        )

        if !result.success {
            throw TranscriptionError.transcriptionFailed(result.stderr)
        }

        // Parse VTT file
        let vttURL = outputBase.appendingPathExtension("vtt")
        defer { try? FileManager.default.removeItem(at: vttURL) }

        guard FileManager.default.fileExists(atPath: vttURL.path) else {
            return []
        }

        let vttContent = try String(contentsOf: vttURL, encoding: .utf8)
        return parseVTT(content: vttContent, speaker: speaker)
    }

    /// Parse VTT format: "00:00:00.000 --> 00:00:02.500\nText"
    private func parseVTT(content: String, speaker: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        let lines = content.components(separatedBy: .newlines)

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Look for timestamp line: "00:00:00.000 --> 00:00:02.500"
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2,
                   let startMs = parseTimestamp(parts[0].trimmingCharacters(in: .whitespaces)),
                   let endMs = parseTimestamp(parts[1].trimmingCharacters(in: .whitespaces)) {

                    // Collect text lines until empty line or next timestamp
                    var textLines: [String] = []
                    i += 1
                    while i < lines.count {
                        let textLine = lines[i].trimmingCharacters(in: .whitespaces)
                        if textLine.isEmpty || textLine.contains("-->") {
                            break
                        }
                        textLines.append(textLine)
                        i += 1
                    }

                    let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        segments.append(TranscriptSegment(
                            startMs: startMs,
                            endMs: endMs,
                            speaker: speaker,
                            text: text
                        ))
                    }
                    continue
                }
            }
            i += 1
        }

        return segments
    }

    /// Parse VTT timestamp "00:00:00.000" to milliseconds
    private func parseTimestamp(_ timestamp: String) -> Int? {
        // Format: HH:MM:SS.mmm or MM:SS.mmm
        let parts = timestamp.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        let hours: Int
        let minutes: Int
        let secondsPart: String

        if parts.count == 3 {
            hours = Int(parts[0]) ?? 0
            minutes = Int(parts[1]) ?? 0
            secondsPart = parts[2]
        } else {
            hours = 0
            minutes = Int(parts[0]) ?? 0
            secondsPart = parts[1]
        }

        let secondsParts = secondsPart.components(separatedBy: ".")
        let seconds = Int(secondsParts[0]) ?? 0
        let millis = secondsParts.count > 1 ? Int(secondsParts[1].prefix(3)) ?? 0 : 0

        return (hours * 3600 + minutes * 60 + seconds) * 1000 + millis
    }

    /// Merge two transcript streams by timestamp
    private func mergeTranscripts(mic: [TranscriptSegment], system: [TranscriptSegment]) -> [TranscriptSegment] {
        var merged = mic + system
        merged.sort()
        return merged
    }

    /// Format merged transcript with speaker labels
    private func formatDiarizedTranscript(segments: [TranscriptSegment], outputURL: URL, participants: [String] = []) throws {
        var lines: [String] = ["# Transcript", ""]

        // Add participants header if available
        if !participants.isEmpty {
            lines.append("**Participants:** \(participants.joined(separator: ", "))")
            lines.append("")
        }

        var currentSpeaker = ""
        for segment in segments {
            if segment.speaker != currentSpeaker {
                if !currentSpeaker.isEmpty {
                    lines.append("")  // Blank line between speakers
                }
                currentSpeaker = segment.speaker
                lines.append("**\(segment.speaker):**")
            }
            lines.append(segment.text)
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func findModel() -> String? {
        let searchPaths = [
            NSHomeDirectory() + "/.munin/models/ggml-base.en.bin",
            NSHomeDirectory() + "/.munin/models/ggml-base.bin",
            NSHomeDirectory() + "/.munin/models/ggml-small.en.bin",
            NSHomeDirectory() + "/.munin/models/ggml-small.bin",
            "/usr/local/share/whisper/models/ggml-base.en.bin"
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}
