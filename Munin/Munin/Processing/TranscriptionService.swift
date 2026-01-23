import Foundation

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

    func transcribe(audioURL: URL, outputURL: URL) async throws {
        guard let whisperPath = whisperPath else {
            throw TranscriptionError.whisperNotFound
        }

        guard let modelPath = modelPath else {
            throw TranscriptionError.modelNotFound
        }

        // Convert m4a to wav for whisper.cpp
        let wavURL = audioURL.deletingPathExtension().appendingPathExtension("wav")
        try await convertToWav(inputURL: audioURL, outputURL: wavURL)

        // Run whisper.cpp
        let result = try await ProcessRunner.run(
            executablePath: whisperPath,
            arguments: [
                "-m", modelPath,
                "-f", wavURL.path,
                "-otxt",
                "-of", outputURL.deletingPathExtension().path, // whisper adds .txt
                "--print-progress"
            ],
            timeout: 1800 // 30 minutes for long recordings
        )

        if !result.success {
            throw TranscriptionError.transcriptionFailed(result.stderr)
        }

        // Rename .txt to .md and format
        let txtURL = outputURL.deletingPathExtension().appendingPathExtension("txt")
        if FileManager.default.fileExists(atPath: txtURL.path) {
            let content = try String(contentsOf: txtURL, encoding: .utf8)
            try formatTranscript(content: content, outputURL: outputURL)
            try? FileManager.default.removeItem(at: txtURL)
        }

        // Clean up wav file
        try? FileManager.default.removeItem(at: wavURL)
    }

    private func convertToWav(inputURL: URL, outputURL: URL) async throws {
        // Use afconvert to convert to 16kHz 16-bit PCM WAV
        let afconvertPath = "/usr/bin/afconvert"

        let result = try await ProcessRunner.run(
            executablePath: afconvertPath,
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                inputURL.path,
                outputURL.path
            ],
            timeout: 300
        )

        if !result.success {
            throw TranscriptionError.conversionFailed
        }
    }

    private func formatTranscript(content: String, outputURL: URL) throws {
        let formatted = """
            # Transcript

            \(content)
            """
        try formatted.write(to: outputURL, atomically: true, encoding: .utf8)
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
