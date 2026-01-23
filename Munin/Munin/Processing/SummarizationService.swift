import Foundation

final class SummarizationService {
    enum SummarizationError: Error, LocalizedError {
        case claudeNotFound
        case claudeNotAuthenticated
        case summarizationFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .claudeNotFound:
                return "Claude CLI not found. Please install it: npm install -g @anthropic-ai/claude-code"
            case .claudeNotAuthenticated:
                return "Claude CLI not authenticated. Please run: claude auth login"
            case .summarizationFailed(let message):
                return "Summarization failed: \(message)"
            case .timeout:
                return "Summarization timed out"
            }
        }
    }

    private let claudePath: String?

    init() {
        self.claudePath = ProcessRunner.findExecutable(
            name: "claude",
            additionalPaths: [
                "/usr/local/bin/claude",
                NSHomeDirectory() + "/.npm-global/bin/claude",
                NSHomeDirectory() + "/node_modules/.bin/claude"
            ]
        )
    }

    func summarize(transcriptURL: URL, outputURL: URL) async throws {
        guard let claudePath = claudePath else {
            throw SummarizationError.claudeNotFound
        }

        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)

        let prompt = """
            Summarize this meeting transcript. Include:

            ## Key Points
            - Main topics discussed
            - Important decisions made

            ## Action Items
            - Tasks assigned with owners if mentioned
            - Deadlines if mentioned

            ## Summary
            A brief 2-3 sentence summary of the meeting.

            ---
            Transcript:
            \(transcript)
            """

        // Run claude CLI with the prompt (-p for print mode, outputs just the response)
        let result = try await ProcessRunner.run(
            executablePath: claudePath,
            arguments: ["-p", prompt],
            timeout: 300 // 5 minutes for long transcripts
        )

        // Check for authentication issues
        if result.stderr.contains("not authenticated") || result.stderr.contains("auth") {
            throw SummarizationError.claudeNotAuthenticated
        }

        if !result.success {
            // Don't fail hard - summarization is optional
            print("Summarization failed: \(result.stderr)")
            throw SummarizationError.summarizationFailed(result.stderr)
        }

        // Write the summary
        let summary = """
            # Meeting Summary

            \(result.stdout)
            """
        try summary.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Checks if claude is available and authenticated
    func isAvailable() async -> Bool {
        guard let claudePath = claudePath else {
            return false
        }

        do {
            let result = try await ProcessRunner.run(
                executablePath: claudePath,
                arguments: ["--version"],
                timeout: 10
            )
            return result.success
        } catch {
            return false
        }
    }
}
