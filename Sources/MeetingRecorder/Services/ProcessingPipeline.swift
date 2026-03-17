import AVFoundation
import Foundation

struct ProcessingPipeline {
    let store: MeetingStore
    private let mixProcessingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let mixOutputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!

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
                return try MixingState(source: source, outputFormat: mixProcessingFormat)
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
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )

        while true {
            let buffers = try states.map { try $0.readConvertedChunk(frameCount: frameChunk) }
            let maxFrameLength = buffers.map(\.frameLength).max() ?? 0
            if maxFrameLength == 0 {
                break
            }

            guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: mixProcessingFormat, frameCapacity: maxFrameLength) else {
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

            let outputBuffer = try makeInt16Buffer(from: mixedBuffer)
            try outputFile.write(from: outputBuffer)
        }

        try writeTailIntegrityReport(for: outputURL)
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

private extension ProcessingPipeline {
    func makeInt16Buffer(from sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let inputChannel = sourceBuffer.floatChannelData?.pointee else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 48,
                userInfo: [NSLocalizedDescriptionKey: "Unable to access mixed float audio samples."]
            )
        }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: mixOutputFormat, frameCapacity: sourceBuffer.frameLength) else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 49,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate 16-bit output buffer."]
            )
        }
        outputBuffer.frameLength = sourceBuffer.frameLength
        guard let outputChannel = outputBuffer.int16ChannelData?.pointee else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 50,
                userInfo: [NSLocalizedDescriptionKey: "Unable to access 16-bit output audio samples."]
            )
        }

        for frameIndex in 0 ..< Int(sourceBuffer.frameLength) {
            let sample = min(1, max(-1, inputChannel[frameIndex]))
            outputChannel[frameIndex] = Int16((sample * Float(Int16.max)).rounded())
        }

        return outputBuffer
    }

    func writeTailIntegrityReport(for audioURL: URL) throws {
        let report = try TailIntegrityAnalyzer.inspect(audioURL: audioURL)
        let diagnosticsURL = audioURL.deletingLastPathComponent().appendingPathComponent("audio-debug.txt")
        try report.description.write(to: diagnosticsURL, atomically: true, encoding: .utf8)
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

private enum TailIntegrityAnalyzer {
    private static let maxAnalysisSeconds: Double = 180
    private static let blockDurationSeconds: Double = 0.5
    private static let loudnessFloor: Double = 0.003

    static func inspect(audioURL: URL) throws -> TailIntegrityReport {
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else {
            return TailIntegrityReport(
                analyzedSeconds: 0,
                blockDurationSeconds: blockDurationSeconds,
                blockCount: 0,
                loudBlockCount: 0,
                uniqueLoudBlockCount: 0,
                maxConsecutiveDuplicateBlocks: 0,
                suspicious: false
            )
        }

        let maxFrames = AVAudioFramePosition(maxAnalysisSeconds * sampleRate)
        let framesToRead = min(file.length, maxFrames)
        file.framePosition = max(file.length - framesToRead, 0)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(framesToRead)) else {
            throw NSError(
                domain: "ProcessingPipeline",
                code: 51,
                userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio diagnostics buffer."]
            )
        }
        try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))

        let samples = normalizedMonoSamples(from: buffer)
        let framesPerBlock = max(Int(sampleRate * blockDurationSeconds), 1)
        guard samples.count >= framesPerBlock else {
            return TailIntegrityReport(
                analyzedSeconds: Double(samples.count) / sampleRate,
                blockDurationSeconds: blockDurationSeconds,
                blockCount: 0,
                loudBlockCount: 0,
                uniqueLoudBlockCount: 0,
                maxConsecutiveDuplicateBlocks: 0,
                suspicious: false
            )
        }

        var blockHashes: [UInt64] = []
        var loudBlockHashes = Set<UInt64>()
        var loudBlockCount = 0
        var maxConsecutiveDuplicateBlocks = 1
        var currentRun = 1

        for start in stride(from: 0, to: samples.count - framesPerBlock + 1, by: framesPerBlock) {
            let end = start + framesPerBlock
            let block = samples[start..<end]
            let hash = hashBlock(block)
            blockHashes.append(hash)

            let rms = sqrt(block.reduce(0) { partial, sample in
                partial + (sample * sample)
            } / Double(framesPerBlock))
            if rms >= loudnessFloor {
                loudBlockCount += 1
                loudBlockHashes.insert(hash)
            }

            if blockHashes.count >= 2, blockHashes[blockHashes.count - 2] == hash {
                currentRun += 1
            } else {
                currentRun = 1
            }
            maxConsecutiveDuplicateBlocks = max(maxConsecutiveDuplicateBlocks, currentRun)
        }

        let uniqueLoudBlockCount = loudBlockHashes.count
        let suspicious =
            maxConsecutiveDuplicateBlocks >= 12 ||
            (loudBlockCount >= 24 && uniqueLoudBlockCount <= max(4, loudBlockCount / 4))

        return TailIntegrityReport(
            analyzedSeconds: Double(samples.count) / sampleRate,
            blockDurationSeconds: blockDurationSeconds,
            blockCount: blockHashes.count,
            loudBlockCount: loudBlockCount,
            uniqueLoudBlockCount: uniqueLoudBlockCount,
            maxConsecutiveDuplicateBlocks: maxConsecutiveDuplicateBlocks,
            suspicious: suspicious
        )
    }

    private static func normalizedMonoSamples(from buffer: AVAudioPCMBuffer) -> [Double] {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }

        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return [] }
            let samples = channelData.pointee
            return (0..<frameLength).map { Double(samples[$0]) / Double(Int16.max) }
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return [] }
            let samples = channelData.pointee
            return (0..<frameLength).map { Double(samples[$0]) }
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return [] }
            let samples = channelData.pointee
            return (0..<frameLength).map { Double(samples[$0]) / Double(Int32.max) }
        default:
            return []
        }
    }

    private static func hashBlock(_ block: ArraySlice<Double>) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for sample in block {
            let quantized = Int16((min(1, max(-1, sample)) * Double(Int16.max)).rounded())
            hash ^= UInt64(UInt16(bitPattern: quantized))
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

private struct TailIntegrityReport {
    let analyzedSeconds: Double
    let blockDurationSeconds: Double
    let blockCount: Int
    let loudBlockCount: Int
    let uniqueLoudBlockCount: Int
    let maxConsecutiveDuplicateBlocks: Int
    let suspicious: Bool
}

private extension TailIntegrityReport {
    var description: String {
        """
        analyzedSeconds=\(String(format: "%.1f", analyzedSeconds))
        blockDurationSeconds=\(String(format: "%.1f", blockDurationSeconds))
        blockCount=\(blockCount)
        loudBlockCount=\(loudBlockCount)
        uniqueLoudBlockCount=\(uniqueLoudBlockCount)
        maxConsecutiveDuplicateBlocks=\(maxConsecutiveDuplicateBlocks)
        suspicious=\(suspicious)
        """
    }
}
