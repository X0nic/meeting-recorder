import Foundation

enum ProcessRunnerError: LocalizedError {
    case commandNotFound(String)
    case nonZeroExit(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let name):
            return "\(name) was not found in PATH."
        case .nonZeroExit(let executable, let code, let output):
            if output.isEmpty {
                return "\(executable) exited with status \(code)."
            }
            return "\(executable) exited with status \(code): \(output)"
        }
    }
}

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ProcessRunner {
    private static let fallbackSearchPaths = [
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin",
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/homebrew/sbin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    static func executableURL(
        named name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        resolveExecutable(named: name, environment: environment)
    }

    static func run(
        executable: String,
        arguments: [String],
        input: Data? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProcessResult {
        guard let executableURL = resolveExecutable(named: executable, environment: environment) else {
            throw ProcessRunnerError.commandNotFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = mergedEnvironment(environment)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            let stdoutData = MutableDataBox()
            let stderrData = MutableDataBox()
            let completion = ProcessCompletionGate(continuation: continuation, executable: executable, stdout: stdoutData, stderr: stderrData)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stdoutData.append(chunk)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    stderrData.append(chunk)
                }
            }

            if let input {
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                stdinPipe.fileHandleForWriting.writeabilityHandler = { handle in
                    handle.write(input)
                    try? handle.close()
                    handle.writeabilityHandler = nil
                }
            }

            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                completion.finish(exitCode: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                completion.fail(error)
            }
        }
    }

    private static func resolveExecutable(named name: String, environment: [String: String]) -> URL? {
        let candidate = URL(fileURLWithPath: name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        for directory in resolvedSearchPaths(from: environment) {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func mergedEnvironment(_ environment: [String: String]) -> [String: String] {
        var merged = environment
        merged["PATH"] = resolvedSearchPaths(from: environment).joined(separator: ":")
        return merged
    }

    private static func resolvedSearchPaths(from environment: [String: String]) -> [String] {
        var orderedPaths: [String] = []
        var seenPaths = Set<String>()

        let inheritedPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        for path in inheritedPaths + fallbackSearchPaths {
            guard !path.isEmpty, !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)
            orderedPaths.append(path)
        }

        return orderedPaths
    }
}

private final class MutableDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ProcessCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private let executable: String
    private let stdout: MutableDataBox
    private let stderr: MutableDataBox

    init(
        continuation: CheckedContinuation<ProcessResult, Error>,
        executable: String,
        stdout: MutableDataBox,
        stderr: MutableDataBox
    ) {
        self.continuation = continuation
        self.executable = executable
        self.stdout = stdout
        self.stderr = stderr
    }

    func finish(exitCode: Int32) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        let stdoutString = String(data: stdout.value, encoding: .utf8) ?? ""
        let stderrString = String(data: stderr.value, encoding: .utf8) ?? ""
        let result = ProcessResult(stdout: stdoutString, stderr: stderrString, exitCode: exitCode)
        if exitCode == 0 {
            continuation.resume(returning: result)
        } else {
            let diagnostic = stderrString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(throwing: ProcessRunnerError.nonZeroExit(executable, exitCode, diagnostic))
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}
