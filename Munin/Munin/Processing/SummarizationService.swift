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

        let promptData = Data(prompt.utf8)

        // Run claude CLI with the prompt via stdin to avoid command-line length limits.
        // Optimization flags: skip session persistence, slash commands, and MCP servers for faster startup
        let result: ProcessRunner.Result
        do {
            result = try await ProcessRunner.run(
                executablePath: claudePath,
                arguments: [
                    "-p",
                    "--model", "sonnet",
                    "--no-session-persistence",
                    "--disable-slash-commands",
                    "--strict-mcp-config"
                ],
                stdinData: promptData,
                timeout: 300 // 5 minutes for long transcripts
            )
        } catch ProcessRunner.ProcessError.timeout {
            throw SummarizationError.timeout
        }

        let finalResult: ProcessRunner.Result
        if !result.success,
           shouldRetryWithArgument(result.stderr),
           promptData.count <= 100_000 {
            do {
                finalResult = try await ProcessRunner.run(
                    executablePath: claudePath,
                    arguments: [
                        "-p",
                        "--model", "sonnet",
                        "--no-session-persistence",
                        "--disable-slash-commands",
                        "--strict-mcp-config",
                        prompt
                    ],
                    timeout: 300
                )
            } catch ProcessRunner.ProcessError.timeout {
                throw SummarizationError.timeout
            }
        } else {
            finalResult = result
        }

        // Check for authentication issues
        if finalResult.stderr.contains("not authenticated") || finalResult.stderr.contains("auth") {
            throw SummarizationError.claudeNotAuthenticated
        }

        if !finalResult.success {
            // Don't fail hard - summarization is optional
            print("Summarization failed: \(finalResult.stderr)")
            throw SummarizationError.summarizationFailed(finalResult.stderr)
        }

        // Write the summary
        let summary = """
            # Meeting Summary

            \(finalResult.stdout)
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

    private func shouldRetryWithArgument(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("usage") || lowered.contains("prompt") || lowered.contains("missing")
    }
}
