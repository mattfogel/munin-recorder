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

        var segmentationFlags: [String] = [
            "--split-on-word",
            "--max-len", "120"
        ]
        let vadModelPath = NSHomeDirectory() + "/.munin/models/ggml-silero-v6.2.0.bin"
        if FileManager.default.fileExists(atPath: vadModelPath) {
            segmentationFlags += [
                "--vad",
                "--vad-model", vadModelPath,
                "--vad-threshold", "0.60",
                "--vad-min-silence-duration-ms", "300",
                "--vad-max-speech-duration-s", "15",
                "--vad-speech-pad-ms", "20"
            ]
        }

        // Run whisper with VTT + JSON + word output for timestamps
        let result = try await ProcessRunner.run(
            executablePath: whisperPath,
            arguments: [
                "-m", modelPath,
                "-f", wavURL.path,
                "-ovtt",  // VTT format has timestamps
                "-oj",
                "-owts",
                "-of", outputBase.path,
                "--print-progress"
            ] + segmentationFlags,
            timeout: 1800
        )

        if !result.success {
            throw TranscriptionError.transcriptionFailed(result.stderr)
        }

        let vttURL = outputBase.appendingPathExtension("vtt")
        let jsonURL = outputBase.appendingPathExtension("json")
        let wtsURL = outputBase.appendingPathExtension("wts")

        defer {
            try? FileManager.default.removeItem(at: vttURL)
            try? FileManager.default.removeItem(at: jsonURL)
            try? FileManager.default.removeItem(at: wtsURL)
        }

        let wordSegments = parseWordTimings(outputBase: outputBase, speaker: speaker)
        if !wordSegments.isEmpty {
            return wordSegments
        }

        guard FileManager.default.fileExists(atPath: vttURL.path) else {
            return []
        }

        let vttContent = try String(contentsOf: vttURL, encoding: .utf8)
        return parseVTT(content: vttContent, speaker: speaker)
    }

    private struct WordTiming {
        let startMs: Int
        let endMs: Int
        let text: String
    }

    private func parseWordTimings(outputBase: URL, speaker: String) -> [TranscriptSegment] {
        let wtsURL = outputBase.appendingPathExtension("wts")
        if let words = parseWTS(url: wtsURL), !words.isEmpty {
            return segmentWords(words, speaker: speaker)
        }

        let jsonURL = outputBase.appendingPathExtension("json")
        if let words = parseJSONWords(url: jsonURL), !words.isEmpty {
            return segmentWords(words, speaker: speaker)
        }

        return []
    }

    private func parseWTS(url: URL) -> [WordTiming]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        var words: [WordTiming] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let cleaned = trimmed
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .replacingOccurrences(of: ",", with: " ")

            let tokens = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if tokens.count < 3 { continue }

            var startToken: String?
            var endToken: String?
            var wordTokens: [String] = []

            if let arrowIndex = tokens.firstIndex(of: "-->") {
                if arrowIndex > 0, arrowIndex + 1 < tokens.count {
                    startToken = tokens[arrowIndex - 1]
                    endToken = tokens[arrowIndex + 1]
                    if arrowIndex + 2 < tokens.count {
                        wordTokens = Array(tokens[(arrowIndex + 2)...])
                    }
                }
            } else {
                startToken = tokens[0]
                endToken = tokens[1]
                wordTokens = Array(tokens[2...])
            }

            guard let start = startToken, let end = endToken,
                  let startMs = parseTimeToken(start, key: "start"),
                  let endMs = parseTimeToken(end, key: "end") else {
                continue
            }

            let word = wordTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if word.isEmpty { continue }
            words.append(WordTiming(startMs: startMs, endMs: endMs, text: word))
        }

        return words
    }

    private func parseJSONWords(url: URL) -> [WordTiming]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let root = jsonObject as? [String: Any],
              let segments = root["segments"] as? [[String: Any]] else {
            return nil
        }

        var words: [WordTiming] = []
        for segment in segments {
            if let wordsArray = segment["words"] as? [[String: Any]] {
                for wordInfo in wordsArray {
                    guard let wordText = (wordInfo["word"] as? String) ?? (wordInfo["text"] as? String),
                          let startMs = parseTimeValue(wordInfo["start"], key: "start") ?? parseTimeValue(wordInfo["t0"], key: "t0"),
                          let endMs = parseTimeValue(wordInfo["end"], key: "end") ?? parseTimeValue(wordInfo["t1"], key: "t1") else {
                        continue
                    }
                    let trimmed = wordText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    words.append(WordTiming(startMs: startMs, endMs: endMs, text: trimmed))
                }
            }
        }

        return words
    }

    private func parseTimeToken(_ token: String, key: String) -> Int? {
        if token.contains(":") {
            return parseTimestamp(token)
        }
        if let value = Double(token) {
            return convertTimeValueToMs(value, key: key)
        }
        return nil
    }

    private func parseTimeValue(_ value: Any?, key: String) -> Int? {
        if let doubleValue = value as? Double {
            return convertTimeValueToMs(doubleValue, key: key)
        }
        if let intValue = value as? Int {
            return convertTimeValueToMs(Double(intValue), key: key)
        }
        if let stringValue = value as? String, let doubleValue = Double(stringValue) {
            return convertTimeValueToMs(doubleValue, key: key)
        }
        return nil
    }

    private func convertTimeValueToMs(_ value: Double, key: String) -> Int {
        if key == "t0" || key == "t1" {
            return Int((value * 10.0).rounded())
        }
        if value > 1000 {
            return Int(value.rounded())
        }
        return Int((value * 1000.0).rounded())
    }

    private func segmentWords(_ words: [WordTiming], speaker: String) -> [TranscriptSegment] {
        guard !words.isEmpty else { return [] }

        let wordGapMs = 800
        let punctuationGapMs = 250
        let maxSegmentChars = 160

        var segments: [TranscriptSegment] = []
        var currentText = ""
        var segmentStart = words[0].startMs
        var segmentEnd = words[0].endMs
        var previousEnd = words[0].endMs
        var previousWord = ""

        for word in words {
            let gap = max(0, word.startMs - previousEnd)
            let endsSentence = previousWord.trimmingCharacters(in: .whitespacesAndNewlines).last
                .map { ".!?".contains($0) } ?? false

            let projectedLength = currentText.count + word.text.count + 1
            let shouldBreak = currentText.isEmpty == false && (
                gap >= wordGapMs ||
                (endsSentence && gap >= punctuationGapMs) ||
                projectedLength >= maxSegmentChars
            )

            if shouldBreak {
                segments.append(TranscriptSegment(
                    startMs: segmentStart,
                    endMs: segmentEnd,
                    speaker: speaker,
                    text: currentText.trimmingCharacters(in: .whitespaces)
                ))
                currentText = ""
                segmentStart = word.startMs
            }

            appendWord(word.text, to: &currentText)
            segmentEnd = word.endMs
            previousEnd = word.endMs
            previousWord = word.text
        }

        if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
            segments.append(TranscriptSegment(
                startMs: segmentStart,
                endMs: segmentEnd,
                speaker: speaker,
                text: currentText.trimmingCharacters(in: .whitespaces)
            ))
        }

        return segments
    }

    private func appendWord(_ word: String, to text: inout String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let noSpaceBefore = ".,!?;:%)]"
        let noSpaceAfter = "("

        if text.isEmpty {
            text = trimmed
            return
        }

        if let first = trimmed.first, noSpaceBefore.contains(first) {
            text += trimmed
            return
        }

        if trimmed.hasPrefix("'") {
            text += trimmed
            return
        }

        if let last = text.last, noSpaceAfter.contains(last) {
            text += trimmed
            return
        }

        text += " " + trimmed
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

        let gapThresholdMs = 1500
        var currentSpeaker = ""
        var previousEndMs: Int? = nil
        for segment in segments {
            let gapMs: Int
            if let previousEndMs = previousEndMs {
                gapMs = max(0, segment.startMs - previousEndMs)
            } else {
                gapMs = 0
            }

            if segment.speaker != currentSpeaker || gapMs >= gapThresholdMs {
                if !currentSpeaker.isEmpty {
                    lines.append("")  // Blank line between speakers or long pauses
                }
                currentSpeaker = segment.speaker
                lines.append("**\(segment.speaker):**")
            }

            let timestamp = formatTimestamp(segment.startMs)
            lines.append("[\(timestamp)] \(segment.text)")
            previousEndMs = segment.endMs
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Format milliseconds into "HH:MM:SS.mmm"
    private func formatTimestamp(_ ms: Int) -> String {
        let totalSeconds = max(0, ms) / 1000
        let millis = max(0, ms) % 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
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
