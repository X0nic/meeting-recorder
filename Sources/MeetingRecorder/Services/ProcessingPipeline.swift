import AVFoundation
import Foundation

struct ProcessingPipeline {
    let store: MeetingStore
    private let mixOutputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func discoverWhisperModels() -> [WhisperModelInfo] {
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/whisper-models", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file

        return urls
            .filter { $0.lastPathComponent.hasPrefix("ggml-") && $0.pathExtension == "bin" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return WhisperModelInfo(
                    id: url.lastPathComponent,
                    sizeName: url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ggml-", with: ""),
                    fileURL: url,
                    fileSizeDescription: byteFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0))
                )
            }
            .sorted { $0.sizeName < $1.sizeName }
    }

    func validateTranscriptionTools() throws {
        guard ProcessRunner.executableURL(named: "whisper-cli") != nil else {
            throw ProcessRunnerError.commandNotFound("whisper-cli")
        }
    }

    func validateNotesTools() throws {
        guard ProcessRunner.executableURL(named: "claude") != nil else {
            throw ProcessRunnerError.commandNotFound("claude")
        }
    }

    func transcribe(audioURL: URL, model: WhisperModelInfo) async throws -> URL {
        try validateTranscriptionTools()
        let prefixURL = audioURL.deletingLastPathComponent().appendingPathComponent("transcript")
        _ = try await ProcessRunner.run(
            executable: "whisper-cli",
            arguments: ["-m", model.fileURL.path, "-f", audioURL.path, "-otxt", "-of", prefixURL.path, "-ng"]
        )
        return prefixURL.appendingPathExtension("txt")
    }

    func generateNotes(transcriptURL: URL) async throws -> URL {
        try validateNotesTools()
        let transcript = try Data(contentsOf: transcriptURL)
        let notesURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("notes.md")
        let prompt = """
        Turn this meeting transcript into concise notes using these sections:
        Summary
        Key Discussion Points
        Decisions Made
        Action Items
        Follow-ups

        Transcript:
        """
        let input = Data(prompt.utf8) + transcript
        let result = try await ProcessRunner.run(
            executable: "claude",
            arguments: ["--print"],
            input: input
        )
        try result.stdout.write(to: notesURL, atomically: true, encoding: .utf8)
        return notesURL
    }

    func mixRecordedAudio(systemAudioURL: URL?, microphoneAudioURL: URL?, outputURL: URL) throws -> URL {
        let candidates = [
            MixingSource(url: systemAudioURL, gain: 0.7, label: "system audio"),
            MixingSource(url: microphoneAudioURL, gain: 0.7, label: "microphone audio")
        ]

        let readableSources = candidates.compactMap { source -> MixingSource? in
            guard let url = source.url, FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return source
        }

        guard !readableSources.isEmpty else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "No recorded audio streams were available to mix."]
            )
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let frameChunk: AVAudioFrameCount = 2_048
        var stateErrors: [String] = []
        let states = readableSources.compactMap { source -> MixingState? in
            do {
                return try MixingState(source: source, outputFormat: mixOutputFormat)
            } catch {
                stateErrors.append(error.localizedDescription)
                return nil
            }
        }

        guard !states.isEmpty else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 47,
                userInfo: [NSLocalizedDescriptionKey: stateErrors.joined(separator: " ")]
            )
        }

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: mixOutputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        while true {
            let buffers = try states.map { try $0.readConvertedChunk(frameCount: frameChunk) }
            let maxFrameLength = buffers.map(\.frameLength).max() ?? 0
            if maxFrameLength == 0 {
                break
            }

            guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: mixOutputFormat, frameCapacity: maxFrameLength) else {
                throw NSError(
                    domain: "ProcessingPipeline",
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to allocate a mixed audio buffer."]
                )
            }
            mixedBuffer.frameLength = maxFrameLength

            guard let outputChannel = mixedBuffer.floatChannelData?.pointee else {
                throw NSError(
                    domain: "ProcessingPipeline",
                    code: 43,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to access mixed audio samples."]
                )
            }

            for frameIndex in 0 ..< Int(maxFrameLength) {
                outputChannel[frameIndex] = 0
            }

            for (index, buffer) in buffers.enumerated() where buffer.frameLength > 0 {
                guard let inputChannel = buffer.floatChannelData?.pointee else { continue }
                let gain = states[index].gain
                for frameIndex in 0 ..< Int(buffer.frameLength) {
                    let mixedSample = outputChannel[frameIndex] + (inputChannel[frameIndex] * gain)
                    outputChannel[frameIndex] = min(1, max(-1, mixedSample))
                }
            }

            try outputFile.write(from: mixedBuffer)
        }

        return outputURL
    }

    func importAudioTrack(from url: URL, into directory: URL, outputFileBasename: String = "audio") async throws -> URL {
        if ["wav", "mp3", "m4a", "caf", "aiff"].contains(url.pathExtension.lowercased()) {
            let destination = directory.appendingPathComponent("\(outputFileBasename).\(url.pathExtension.lowercased())")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        }

        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "ProcessingPipeline", code: 40, userInfo: [NSLocalizedDescriptionKey: "Unable to export audio from imported file."])
        }

        let outputURL = directory.appendingPathComponent("\(outputFileBasename).m4a")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a
        try await export.export(to: outputURL, as: .m4a)
        return outputURL
    }
}

private struct MixingSource {
    let url: URL?
    let gain: Float
    let label: String
}

private final class MixingState {
    let gain: Float

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var reachedEnd = false
    private var fedEOF = false

    init(source: MixingSource, outputFormat: AVAudioFormat) throws {
        guard let url = source.url else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 44,
                userInfo: [NSLocalizedDescriptionKey: "Missing \(source.label) URL."]
            )
        }

        self.file = try AVAudioFile(forReading: url)
        self.sourceFormat = file.processingFormat
        self.outputFormat = outputFormat
        self.gain = source.gain

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 45,
                userInfo: [NSLocalizedDescriptionKey: "Unable to convert \(source.label) into the mixed output format."]
            )
        }
        self.converter = converter
        self.converter.downmix = true
    }

    func readConvertedChunk(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 46,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate an audio conversion buffer."]
            )
        }

        if reachedEnd {
            outputBuffer.frameLength = 0
            return outputBuffer
        }

        let eofBox = EOFBox(value: fedEOF)
        var conversionError: NSError?
        let sourceFormat = self.sourceFormat
        let file = self.file
        let fedEOF = self.fedEOF
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if fedEOF || eofBox.value {
                outStatus.pointee = .endOfStream
                return nil
            }

            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                outStatus.pointee = .noDataNow
                return nil
            }

            do {
                try file.read(into: inputBuffer, frameCount: frameCount)
            } catch {
                outStatus.pointee = .endOfStream
                eofBox.value = true
                return nil
            }

            if inputBuffer.frameLength == 0 {
                outStatus.pointee = .endOfStream
                eofBox.value = true
                return nil
            }

            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }
        if status == .endOfStream {
            reachedEnd = true
            self.fedEOF = true
        }

        return outputBuffer
    }
}

private final class EOFBox: @unchecked Sendable {
    var value: Bool

    init(value: Bool) {
        self.value = value
    }
}
