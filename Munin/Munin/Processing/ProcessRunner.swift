@preconcurrency import Foundation

final class ProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var success: Bool { exitCode == 0 }
    }

    enum ProcessError: Error, LocalizedError {
        case timeout
        case executableNotFound(String)
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Process timed out"
            case .executableNotFound(let path):
                return "Executable not found: \(path)"
            case .executionFailed(let message):
                return "Execution failed: \(message)"
            }
        }
    }

    /// Runs a process asynchronously with timeout
    static func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 300 // 5 minutes default
    ) async throws -> Result {
        guard FileManager.default.fileExists(atPath: executablePath) else {
            throw ProcessError.executableNotFound(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        if let workingDirectory = workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        if let environment = environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            var didComplete = false
            let timeoutWorkItem = DispatchWorkItem { [weak process] in
                guard !didComplete else { return }
                process?.terminate()
                continuation.resume(throwing: ProcessError.timeout)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            do {
                try process.run()

                DispatchQueue.global().async {
                    process.waitUntilExit()

                    timeoutWorkItem.cancel()
                    guard !didComplete else { return }
                    didComplete = true

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let result = Result(
                        exitCode: process.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? ""
                    )

                    continuation.resume(returning: result)
                }
            } catch {
                timeoutWorkItem.cancel()
                didComplete = true
                continuation.resume(throwing: ProcessError.executionFailed(error.localizedDescription))
            }
        }
    }

    /// Finds an executable in common locations
    static func findExecutable(name: String, additionalPaths: [String] = []) -> String? {
        var searchPaths = additionalPaths

        // Common installation paths
        searchPaths += [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/bin/\(name)",
            NSHomeDirectory() + "/.local/bin/\(name)",
            NSHomeDirectory() + "/bin/\(name)"
        ]

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}
