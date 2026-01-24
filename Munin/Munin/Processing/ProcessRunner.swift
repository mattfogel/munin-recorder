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
        stdinData: Data? = nil,
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

        let stdinPipe = Pipe()
        if stdinData != nil {
            process.standardInput = stdinPipe
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.executionFailed(error.localizedDescription)
        }

        if let stdinData {
            let stdinHandle = stdinPipe.fileHandleForWriting
            DispatchQueue.global().async {
                stdinHandle.write(stdinData)
                stdinHandle.closeFile()
            }
        }

        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)

        do {
            return try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask {
                    async let stdoutData = stdoutPipe.fileHandleForReading.readToEnd()
                    async let stderrData = stderrPipe.fileHandleForReading.readToEnd()

                    let exitCode: Int32 = await withCheckedContinuation { continuation in
                        DispatchQueue.global().async {
                            process.waitUntilExit()
                            continuation.resume(returning: process.terminationStatus)
                        }
                    }

                    let stdout = (try? await stdoutData) ?? Data()
                    let stderr = (try? await stderrData) ?? Data()

                    return Result(
                        exitCode: exitCode,
                        stdout: String(data: stdout, encoding: .utf8) ?? "",
                        stderr: String(data: stderr, encoding: .utf8) ?? ""
                    )
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    process.terminate()
                    throw ProcessError.timeout
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
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
