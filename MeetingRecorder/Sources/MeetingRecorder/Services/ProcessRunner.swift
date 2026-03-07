import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessError: Error, LocalizedError {
    case binaryNotFound(String)
    case failed(command: [String], stderr: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let binary):
            return "Binary not found: \(binary)"
        case .failed(let command, let stderr, let code):
            return "Command failed (\(code)): \(command.joined(separator: " "))\n\(stderr)"
        }
    }
}

actor ProcessRunner {
    func which(_ binary: String) async -> String? {
        let env = ProcessInfo.processInfo.environment
        let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in paths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(binary).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    func run(_ command: [String], input: String? = nil, allowFailure: Bool = false) async throws -> ProcessResult {
        guard let binary = command.first else {
            throw ProcessError.binaryNotFound("<empty>")
        }
        let launchPath: String
        if binary.hasPrefix("/") {
            launchPath = binary
        } else if let resolved = await which(binary) {
            launchPath = resolved
        } else {
            throw ProcessError.binaryNotFound(binary)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = Array(command.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if input != nil {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            if let input {
                stdin.fileHandleForWriting.write(Data(input.utf8))
            }
            stdin.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let result = ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)

        if !allowFailure && result.exitCode != 0 {
            throw ProcessError.failed(command: command, stderr: stderr.isEmpty ? stdout : stderr, code: result.exitCode)
        }

        return result
    }
}
