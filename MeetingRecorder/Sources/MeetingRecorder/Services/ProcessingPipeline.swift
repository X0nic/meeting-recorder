import Foundation

actor ProcessingPipeline {
    private let runner = ProcessRunner()

    func processMeeting(folder: URL, onStep: @escaping @Sendable (Int, ProcessingStep.StepStatus) -> Void) async throws -> ProcessingResult {
        let recordingURL = folder.appendingPathComponent("recording.mov")
        let audioURL = folder.appendingPathComponent("audio.wav")
        let transcriptPrefix = folder.appendingPathComponent("transcript")
        let transcriptURL = folder.appendingPathComponent("transcript.txt")
        let notesURL = folder.appendingPathComponent("notes.md")

        onStep(0, .running)
        try await runner.run([
            "ffmpeg", "-y", "-i", recordingURL.path, "-vn", "-ac", "1", "-ar", "16000", audioURL.path
        ])
        onStep(0, .success)

        onStep(1, .running)
        let model = try await resolveWhisperModelPath()
        try await runner.run([
            "whisper-cli",
            "-m", model.path,
            "-f", audioURL.path,
            "-otxt",
            "-of", transcriptPrefix.path
        ])
        onStep(1, .success)

        let transcript = (try? String(contentsOf: transcriptURL)) ?? ""
        let words = transcript.split { $0.isWhitespace || $0.isNewline }.count

        onStep(2, .running)
        let prompt = notesPrompt(date: Date(), transcript: transcript)
        let notesResult = try await runner.run(["claude"], input: prompt)
        if notesResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PipelineError.emptyClaudeResponse
        }
        try notesResult.stdout.write(to: notesURL, atomically: true, encoding: .utf8)
        onStep(2, .success)

        return ProcessingResult(meetingFolder: folder, transcriptURL: transcriptURL, notesURL: notesURL, wordCount: words)
    }

    func processExternalFile(sourceURL: URL, meetingsRoot: URL, onStep: @escaping @Sendable (Int, ProcessingStep.StepStatus) -> Void) async throws -> ProcessingResult {
        let folder = makeMeetingFolder(root: meetingsRoot)
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
        let recording = folder.appendingPathComponent("recording.\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: recording)

        let audioURL = folder.appendingPathComponent("audio.wav")
        let transcriptPrefix = folder.appendingPathComponent("transcript")
        let transcriptURL = folder.appendingPathComponent("transcript.txt")
        let notesURL = folder.appendingPathComponent("notes.md")

        onStep(0, .running)
        if ext == "wav" {
            try FileManager.default.copyItem(at: recording, to: audioURL)
        } else {
            try await runner.run(["ffmpeg", "-y", "-i", recording.path, "-vn", "-ac", "1", "-ar", "16000", audioURL.path])
        }
        onStep(0, .success)

        onStep(1, .running)
        let model = try await resolveWhisperModelPath()
        try await runner.run(["whisper-cli", "-m", model.path, "-f", audioURL.path, "-otxt", "-of", transcriptPrefix.path])
        onStep(1, .success)

        let transcript = (try? String(contentsOf: transcriptURL)) ?? ""
        let words = transcript.split { $0.isWhitespace || $0.isNewline }.count

        onStep(2, .running)
        let notesResult = try await runner.run(["claude"], input: notesPrompt(date: Date(), transcript: transcript))
        if notesResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PipelineError.emptyClaudeResponse
        }
        try notesResult.stdout.write(to: notesURL, atomically: true, encoding: .utf8)
        onStep(2, .success)

        return ProcessingResult(meetingFolder: folder, transcriptURL: transcriptURL, notesURL: notesURL, wordCount: words)
    }

    private func resolveWhisperModelPath() async throws -> URL {
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/whisper-models", isDirectory: true)

        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true, attributes: nil)

        for model in ["small", "base", "tiny", "medium", "large"] {
            let path = modelDir.appendingPathComponent("ggml-\(model).bin")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }

        let downloadPath = modelDir.appendingPathComponent("ggml-small.bin")
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
        _ = try await runner.run(["curl", "-L", "-o", downloadPath.path, url.absoluteString])
        return downloadPath
    }

    private func notesPrompt(date: Date, transcript: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let label = formatter.string(from: date)

        return """
Generate meeting notes in this exact format:

# Meeting Notes — \(label)

## Summary
Brief 2-3 sentence overview

## Key Discussion Points
- Point 1
- Point 2

## Decisions Made
- Decision 1
- Decision 2

## Action Items
- [ ] Action item (@person if mentioned)

## Follow-ups
- Follow-up item

## Raw Transcript
[link to transcript.txt]

Use the transcript below. Keep headings and structure exactly the same.

Transcript:
\(transcript)
"""
    }

    private func makeMeetingFolder(root: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let folder = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
        return folder
    }
}

enum PipelineError: Error, LocalizedError {
    case emptyClaudeResponse

    var errorDescription: String? {
        switch self {
        case .emptyClaudeResponse:
            return "Claude returned an empty response."
        }
    }
}
