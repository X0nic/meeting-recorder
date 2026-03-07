import Foundation

actor RecorderService {
    private var process: Process?
    private var activeFolder: URL?
    private var startedAt: Date?

    func startRecording(_ configuration: RecordingConfiguration, meetingsRoot: URL) throws -> URL {
        guard process == nil else {
            throw RecorderError.alreadyRecording
        }

        guard let screenIndex = configuration.screen.ffmpegIndex else {
            throw RecorderError.missingScreenDevice
        }
        guard let systemIndex = configuration.systemAudio.avFoundationIndex else {
            throw RecorderError.missingSystemAudioDevice
        }
        guard let micIndex = configuration.microphone.avFoundationIndex else {
            throw RecorderError.missingMicDevice
        }

        let folder = makeMeetingFolder(root: meetingsRoot)
        let recordingURL = folder.appendingPathComponent("recording.mov")
        let logURL = folder.appendingPathComponent("recording.log")
        let logHandle = try FileHandle(forWritingTo: logURL)

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ffmpeg.arguments = ["ffmpeg"] + ffmpegArguments(
            screenIndex: screenIndex,
            systemAudioIndex: systemIndex,
            micAudioIndex: micIndex,
            outputPath: recordingURL.path
        )
        ffmpeg.standardOutput = logHandle
        ffmpeg.standardError = logHandle

        try ffmpeg.run()

        process = ffmpeg
        activeFolder = folder
        startedAt = Date()

        return folder
    }

    func stopRecording() async throws -> URL {
        guard let process, let folder = activeFolder else {
            throw RecorderError.notRecording
        }

        if process.isRunning {
            process.interrupt()
            process.waitUntilExit()
        }

        self.process = nil
        activeFolder = nil

        if let startedAt {
            let duration = Int(Date().timeIntervalSince(startedAt))
            try "duration=\(duration)\n".write(to: folder.appendingPathComponent("meeting.meta"), atomically: true, encoding: .utf8)
            self.startedAt = nil
        }

        return folder
    }

    func forceStopIfNeeded() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        activeFolder = nil
        startedAt = nil
    }

    private func makeMeetingFolder(root: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let folder = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        let logURL = folder.appendingPathComponent("recording.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        return folder
    }

    private func ffmpegArguments(screenIndex: Int, systemAudioIndex: Int, micAudioIndex: Int, outputPath: String) -> [String] {
        var args: [String] = [
            "-y",
            "-f", "avfoundation",
            "-framerate", "30",
            "-capture_cursor", "1",
            "-i", "\(screenIndex):none",
            "-f", "avfoundation",
            "-i", ":\(systemAudioIndex)"
        ]

        if micAudioIndex != systemAudioIndex {
            args += ["-f", "avfoundation", "-i", ":\(micAudioIndex)"]
            args += [
                "-filter_complex", "[1:a][2:a]amix=inputs=2:normalize=0[a]",
                "-map", "0:v",
                "-map", "[a]"
            ]
        } else {
            args += ["-map", "0:v", "-map", "1:a"]
        }

        args += [
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "23",
            "-c:a", "aac",
            "-b:a", "192k",
            outputPath
        ]
        return args
    }
}

enum RecorderError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case missingScreenDevice
    case missingSystemAudioDevice
    case missingMicDevice

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already running."
        case .notRecording:
            return "No active recording."
        case .missingScreenDevice:
            return "Selected screen cannot be mapped to an ffmpeg capture device."
        case .missingSystemAudioDevice:
            return "Selected system audio device is missing an AVFoundation index."
        case .missingMicDevice:
            return "Selected microphone device is missing an AVFoundation index."
        }
    }
}
