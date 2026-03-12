@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenCaptureKitAudioCaptureService: NSObject, @unchecked Sendable {
    weak var delegate: AudioCaptureBackendDelegate?

    var backendKind: AudioCaptureBackendKind { .screenCaptureKit }

    fileprivate enum CaptureMode {
        case monitoring
        case recording(CaptureSessionArtifacts)
    }

    fileprivate struct ProcessedAudioUpdate: Sendable {
        let type: SCStreamOutputType
        let level: Float
        let peakSample: Float
        let sawNonZeroSamples: Bool
        let sampleSummary: String
        let writtenSampleSummary: String?
        let formatDescription: String?
        let eventMessage: String?
        let errorDescription: String?
        let didReceiveFirstFrame: Bool
    }

    private let systemQueue = DispatchQueue(label: "MeetingRecorder.sck.system-audio")
    private let microphoneQueue = DispatchQueue(label: "MeetingRecorder.sck.microphone")
    private let systemProcessor: StreamProcessor
    private let microphoneProcessor: StreamProcessor

    private var stream: SCStream?
    private var timeoutTask: Task<Void, Never>?
    private var mode: CaptureMode?
    private var currentLevels = AudioLevels()
    private var currentState = AudioCaptureBackendState.idle
    private var currentMicrophoneDeviceID: String?

    override init() {
        systemProcessor = StreamProcessor(streamType: .audio)
        microphoneProcessor = StreamProcessor(streamType: .microphone)
        super.init()

        systemProcessor.eventHandler = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.handle(update: update)
            }
        }
        microphoneProcessor.eventHandler = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.handle(update: update)
            }
        }
    }
}

extension ScreenCaptureKitAudioCaptureService: MeetingAudioCaptureBackend {
    func startMonitoring(micDeviceID: String) async throws {
        if case .monitoring = mode, currentMicrophoneDeviceID == micDeviceID, stream != nil {
            return
        }
        if case .monitoring = mode {
            _ = try await stopCapture(expectedRecordingStop: false)
        }
        try await startCapture(micDeviceID: micDeviceID, mode: .monitoring)
    }

    func stopMonitoring() async {
        do {
            _ = try await stopCapture(expectedRecordingStop: false)
        } catch {
            publishFailure(error, failurePoint: "stopping-monitor")
        }
    }

    func startRecording(micDeviceID: String, in directory: URL) async throws {
        let artifacts = CaptureSessionArtifacts(
            mixedAudioURL: nil,
            systemAudioURL: directory.appendingPathComponent("system-audio.caf"),
            microphoneAudioURL: directory.appendingPathComponent("mic-audio.caf")
        )
        try await startCapture(micDeviceID: micDeviceID, mode: .recording(artifacts))
    }

    func stopRecording() async throws -> CaptureSessionArtifacts {
        try await stopCapture(expectedRecordingStop: true)
    }
}

private extension ScreenCaptureKitAudioCaptureService {
    private func startCapture(micDeviceID: String, mode: CaptureMode) async throws {
        if stream != nil {
            _ = try await stopCapture(expectedRecordingStop: false)
        }

        resetState(for: mode)
        publishState()
        publishLevels()

        do {
            try await requestPermissionsIfNeeded()

            switch mode {
            case .monitoring:
                systemProcessor.prepare(recordingURL: nil)
                microphoneProcessor.prepare(recordingURL: nil)
            case .recording(let artifacts):
                systemProcessor.prepare(recordingURL: artifacts.systemAudioURL)
                microphoneProcessor.prepare(recordingURL: artifacts.microphoneAudioURL)
            }

            let shareableContent = try await SCShareableContent.current
            guard let display = shareableContent.displays.first else {
                throw CaptureError("No shareable display was available for ScreenCaptureKit audio capture.")
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.captureMicrophone = true
            configuration.excludesCurrentProcessAudio = false
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            if !micDeviceID.isEmpty {
                configuration.microphoneCaptureDeviceID = micDeviceID
            }

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)

            self.stream = stream
            self.mode = mode
            self.currentMicrophoneDeviceID = micDeviceID
            currentState.failurePoint = nil
            currentState.statusMessage = statusText(prefix: mode, detail: "Starting stream")
            publishState()

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.startCapture { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

            currentState.streamStarted = true
            currentState.statusMessage = statusText(prefix: mode, detail: "Stream started, waiting for audio frames")
            publishState()
            startFrameTimeout()
        } catch {
            systemProcessor.finish()
            microphoneProcessor.finish()
            self.stream = nil
            self.mode = nil
            throw error
        }
    }

    func stopCapture(expectedRecordingStop: Bool) async throws -> CaptureSessionArtifacts {
        timeoutTask?.cancel()
        timeoutTask = nil

        let artifacts = recordingArtifacts
        if let stream {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                stream.stopCapture { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }

        systemProcessor.finish()
        microphoneProcessor.finish()
        self.stream = nil
        self.mode = nil
        self.currentMicrophoneDeviceID = nil

        currentLevels = AudioLevels()
        publishLevels()

        if expectedRecordingStop {
            currentState.statusMessage = captureSummaryStatus()
        } else {
            currentState.statusMessage = "ScreenCaptureKit monitor stopped"
        }
        publishState()

        return artifacts
    }

    var recordingArtifacts: CaptureSessionArtifacts {
        if case .recording(let artifacts) = mode {
            return artifacts
        }
        return CaptureSessionArtifacts()
    }

    private func requestPermissionsIfNeeded() async throws {
        currentState.failurePoint = "permissions"
        currentState.statusMessage = "Checking ScreenCaptureKit permissions"
        publishState()

        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                throw CaptureError("Screen recording permission was not granted.")
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw CaptureError("Microphone permission was not granted.")
            }
        case .denied, .restricted:
            throw CaptureError("Microphone permission was not granted.")
        @unknown default:
            throw CaptureError("Microphone permission status is unavailable.")
        }
    }

    private func handle(update: ProcessedAudioUpdate) {
        if let errorDescription = update.errorDescription {
            publishFailure(CaptureError(errorDescription), failurePoint: "processing-\(update.type.rawValue)")
            return
        }

        switch update.type {
        case .audio:
            currentLevels.system = AudioSampleMeter.smoothedLevel(previous: currentLevels.system, incoming: update.level)
            currentState.systemRecentPeak = update.peakSample
            currentState.systemSawNonZeroSamples = currentState.systemSawNonZeroSamples || update.sawNonZeroSamples
            currentState.systemSampleSummary = update.sampleSummary
            if let writtenSampleSummary = update.writtenSampleSummary {
                currentState.systemWrittenSampleSummary = writtenSampleSummary
            }
            if let formatDescription = update.formatDescription {
                currentState.systemAudioFormat = formatDescription
            }
            if update.didReceiveFirstFrame {
                currentState.didReceiveSystemAudio = true
                if currentState.didReceiveMicrophoneAudio {
                    currentState.failurePoint = nil
                    currentState.statusMessage = statusText(prefix: mode, detail: "Both audio streams are receiving frames")
                } else {
                    currentState.statusMessage = statusText(prefix: mode, detail: "System-audio frames received")
                }
            }
        case .microphone:
            currentLevels.mic = AudioSampleMeter.smoothedLevel(previous: currentLevels.mic, incoming: update.level)
            currentState.microphoneRecentPeak = update.peakSample
            currentState.microphoneSawNonZeroSamples = currentState.microphoneSawNonZeroSamples || update.sawNonZeroSamples
            currentState.microphoneSampleSummary = update.sampleSummary
            if let writtenSampleSummary = update.writtenSampleSummary {
                currentState.microphoneWrittenSampleSummary = writtenSampleSummary
            }
            if let formatDescription = update.formatDescription {
                currentState.microphoneAudioFormat = formatDescription
            }
            if update.didReceiveFirstFrame {
                currentState.didReceiveMicrophoneAudio = true
                if currentState.didReceiveSystemAudio {
                    currentState.failurePoint = nil
                    currentState.statusMessage = statusText(prefix: mode, detail: "Both audio streams are receiving frames")
                } else {
                    currentState.statusMessage = statusText(prefix: mode, detail: "Microphone frames received")
                }
            }
        case .screen:
            return
        @unknown default:
            return
        }

        publishLevels()
        publishState()
    }

    private func startFrameTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            if self.stream == nil {
                return
            }
            if !self.currentState.didReceiveSystemAudio {
                self.currentState.failurePoint = "waiting-for-system-audio-first-frame"
                self.currentState.statusMessage = self.statusText(prefix: self.mode, detail: "Stream started but no system-audio frames arrived")
            } else if !self.currentState.didReceiveMicrophoneAudio {
                self.currentState.failurePoint = "waiting-for-microphone-first-frame"
                self.currentState.statusMessage = self.statusText(prefix: self.mode, detail: "System audio is active but no microphone frames arrived")
            }
            self.publishState()
        }
    }

    private func captureSummaryStatus() -> String {
        if currentState.didReceiveSystemAudio && currentState.didReceiveMicrophoneAudio {
            return "Capture complete: both raw audio streams were written"
        }
        if currentState.streamStarted && !currentState.didReceiveSystemAudio {
            return "Capture complete: no system-audio frames were received"
        }
        if currentState.streamStarted && !currentState.didReceiveMicrophoneAudio {
            return "Capture complete: no microphone frames were received"
        }
        return "Capture stopped"
    }

    private func resetState(for mode: CaptureMode) {
        timeoutTask?.cancel()
        timeoutTask = nil
        currentLevels = AudioLevels()
        currentState = AudioCaptureBackendState.idle
        currentState.backendKind = backendKind
        currentState.statusMessage = statusText(prefix: mode, detail: "Preparing capture")
        switch mode {
        case .monitoring:
            currentState.systemAudioURL = nil
            currentState.microphoneAudioURL = nil
        case .recording(let artifacts):
            currentState.systemAudioURL = artifacts.systemAudioURL
            currentState.microphoneAudioURL = artifacts.microphoneAudioURL
        }
    }

    private func publishFailure(_ error: Error, failurePoint: String) {
        timeoutTask?.cancel()
        timeoutTask = nil
        systemProcessor.finish()
        microphoneProcessor.finish()
        stream = nil
        mode = nil
        currentMicrophoneDeviceID = nil
        currentState.failurePoint = failurePoint
        currentState.statusMessage = error.localizedDescription
        publishState()
        currentLevels = AudioLevels()
        publishLevels()
    }

    private func statusText(prefix mode: CaptureMode?, detail: String) -> String {
        switch mode {
        case .monitoring:
            return "Monitor: \(detail)"
        case .recording:
            return "Recording: \(detail)"
        case nil:
            return detail
        }
    }

    private func publishLevels() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioCaptureBackend(didUpdateLevels: self.currentLevels)
        }
    }

    private func publishState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioCaptureBackend(didUpdateState: self.currentState)
        }
    }
}

extension ScreenCaptureKitAudioCaptureService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.publishFailure(error, failurePoint: "stream-did-stop")
        }
    }
}

extension ScreenCaptureKitAudioCaptureService: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        switch type {
        case .audio:
            systemProcessor.handle(sampleBuffer: sampleBuffer)
        case .microphone:
            microphoneProcessor.handle(sampleBuffer: sampleBuffer)
        case .screen:
            return
        @unknown default:
            return
        }
    }
}

private struct CaptureError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class StreamProcessor: @unchecked Sendable {
    let streamType: SCStreamOutputType
    var eventHandler: (@Sendable (ScreenCaptureKitAudioCaptureService.ProcessedAudioUpdate) -> Void)?

    private let lock = NSLock()
    private var writer: SampleBufferAudioFileWriter?
    private var didReceiveFirstFrame = false

    init(streamType: SCStreamOutputType) {
        self.streamType = streamType
    }

    func prepare(recordingURL: URL?) {
        lock.lock()
        defer { lock.unlock() }
        didReceiveFirstFrame = false
        if let recordingURL {
            writer = SampleBufferAudioFileWriter(url: recordingURL)
        } else {
            writer = nil
        }
    }

    func finish() {
        lock.lock()
        let writer = self.writer
        self.writer = nil
        lock.unlock()
        writer?.finish()
    }

    func handle(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let writer = self.writer
        let isFirstFrame = !didReceiveFirstFrame
        if isFirstFrame {
            didReceiveFirstFrame = true
        }
        lock.unlock()

        do {
            let sampleInspection = AudioSampleMeter.inspect(sampleBuffer: sampleBuffer)
            if let writer {
                try writer.append(sampleBuffer)
            }
            let formatDescription = writer?.formatDescription ?? AudioSampleMeter.describeFormat(sampleBuffer: sampleBuffer)
            let update = ScreenCaptureKitAudioCaptureService.ProcessedAudioUpdate(
                type: streamType,
                level: AudioSampleMeter.uiLevel(fromPeak: sampleInspection.peakSample),
                peakSample: sampleInspection.peakSample,
                sawNonZeroSamples: sampleInspection.sawNonZeroSamples,
                sampleSummary: sampleInspection.summary,
                writtenSampleSummary: writer?.lastWrittenSampleSummary,
                formatDescription: formatDescription,
                eventMessage: nil,
                errorDescription: nil,
                didReceiveFirstFrame: isFirstFrame
            )
            eventHandler?(update)
        } catch {
            let update = ScreenCaptureKitAudioCaptureService.ProcessedAudioUpdate(
                type: streamType,
                level: 0,
                peakSample: 0,
                sawNonZeroSamples: false,
                sampleSummary: "Inspection failed",
                writtenSampleSummary: writer?.lastWrittenSampleSummary,
                formatDescription: nil,
                eventMessage: nil,
                errorDescription: error.localizedDescription,
                didReceiveFirstFrame: false
            )
            eventHandler?(update)
        }
    }
}

private enum AudioSampleMeter {
    struct SampleInspection {
        let peakSample: Float
        let sawNonZeroSamples: Bool
        let summary: String
    }

    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return 0
        }

        let asbd = streamDescription.pointee
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        guard bitsPerChannel > 0 else {
            return 0
        }

        let bufferListSize = MemoryLayout<AudioBufferList>.size + max(Int(asbd.mChannelsPerFrame) - 1, 0) * MemoryLayout<AudioBuffer>.size
        let audioBufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListPointer.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        var peak: Float = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if bitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                peak = max(peak, peakFloat32(data: data, byteCount: byteCount))
            } else if bitsPerChannel == 16 {
                peak = max(peak, peakInt16(data: data, byteCount: byteCount))
            } else if bitsPerChannel == 32 {
                peak = max(peak, peakInt32(data: data, byteCount: byteCount))
            }
        }

        let clampedPeak = max(peak, 0.000_01)
        let decibels = 20 * log10(clampedPeak)
        let floorDB: Float = -55
        return min(max((decibels - floorDB) / -floorDB, 0), 1)
    }

    static func inspect(sampleBuffer: CMSampleBuffer) -> SampleInspection {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return SampleInspection(peakSample: 0, sawNonZeroSamples: false, summary: "Unreadable format")
        }

        let asbd = streamDescription.pointee
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        guard bitsPerChannel > 0 else {
            return SampleInspection(peakSample: 0, sawNonZeroSamples: false, summary: "Unsupported bit depth")
        }

        let bufferListSize = MemoryLayout<AudioBufferList>.size + max(Int(asbd.mChannelsPerFrame) - 1, 0) * MemoryLayout<AudioBuffer>.size
        let audioBufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListPointer.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else {
            return SampleInspection(peakSample: 0, sawNonZeroSamples: false, summary: "Buffer read failed: \(status)")
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        var peak: Float = 0
        var firstNonZero: Float?

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            if bitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                let inspection = inspectFloat32(data: data, byteCount: byteCount)
                peak = max(peak, inspection.peak)
                firstNonZero = firstNonZero ?? inspection.firstNonZero
            } else if bitsPerChannel == 16 {
                let inspection = inspectInt16(data: data, byteCount: byteCount)
                peak = max(peak, inspection.peak)
                firstNonZero = firstNonZero ?? inspection.firstNonZero
            } else if bitsPerChannel == 32 {
                let inspection = inspectInt32(data: data, byteCount: byteCount)
                peak = max(peak, inspection.peak)
                firstNonZero = firstNonZero ?? inspection.firstNonZero
            }
        }

        let sawNonZeroSamples = (firstNonZero != nil) || peak > 0.000_001
        let firstNonZeroText = firstNonZero.map { String(format: "%.6f", $0) } ?? "none"
        let summary = "peak=\(String(format: "%.6f", peak)) firstNonZero=\(firstNonZeroText)"
        return SampleInspection(peakSample: peak, sawNonZeroSamples: sawNonZeroSamples, summary: summary)
    }

    static func smoothedLevel(previous: Float, incoming: Float) -> Float {
        min(max(max(incoming, previous * 0.82), 0), 1)
    }

    static func describeFormat(sampleBuffer: CMSampleBuffer) -> String {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return "Unknown format"
        }

        let asbd = streamDescription.pointee
        return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel)-bit"
    }

    static func uiLevel(fromPeak peak: Float) -> Float {
        let clampedPeak = max(peak, 0.000_01)
        let decibels = 20 * log10(clampedPeak)
        let floorDB: Float = -55
        return min(max((decibels - floorDB) / -floorDB, 0), 1)
    }

    private static func peakFloat32(data: UnsafeMutableRawPointer, byteCount: Int) -> Float {
        let sampleCount = byteCount / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
        var peak: Float = 0
        for index in 0..<sampleCount {
            peak = max(peak, abs(samples[index]))
        }
        return peak
    }

    private static func inspectFloat32(data: UnsafeMutableRawPointer, byteCount: Int) -> (peak: Float, firstNonZero: Float?) {
        let sampleCount = byteCount / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: sampleCount)
        var peak: Float = 0
        var firstNonZero: Float?
        for index in 0..<sampleCount {
            let sample = samples[index]
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            if firstNonZero == nil, magnitude > 0.000_001 {
                firstNonZero = sample
            }
        }
        return (peak, firstNonZero)
    }

    private static func peakInt16(data: UnsafeMutableRawPointer, byteCount: Int) -> Float {
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
        var peak: Float = 0
        for index in 0..<sampleCount {
            peak = max(peak, abs(Float(samples[index]) / Float(Int16.max)))
        }
        return peak
    }

    private static func inspectInt16(data: UnsafeMutableRawPointer, byteCount: Int) -> (peak: Float, firstNonZero: Float?) {
        let sampleCount = byteCount / MemoryLayout<Int16>.size
        let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
        var peak: Float = 0
        var firstNonZero: Float?
        for index in 0..<sampleCount {
            let sample = Float(samples[index]) / Float(Int16.max)
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            if firstNonZero == nil, magnitude > 0.000_001 {
                firstNonZero = sample
            }
        }
        return (peak, firstNonZero)
    }

    private static func peakInt32(data: UnsafeMutableRawPointer, byteCount: Int) -> Float {
        let sampleCount = byteCount / MemoryLayout<Int32>.size
        let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)
        var peak: Float = 0
        for index in 0..<sampleCount {
            peak = max(peak, abs(Float(samples[index]) / Float(Int32.max)))
        }
        return peak
    }

    private static func inspectInt32(data: UnsafeMutableRawPointer, byteCount: Int) -> (peak: Float, firstNonZero: Float?) {
        let sampleCount = byteCount / MemoryLayout<Int32>.size
        let samples = data.bindMemory(to: Int32.self, capacity: sampleCount)
        var peak: Float = 0
        var firstNonZero: Float?
        for index in 0..<sampleCount {
            let sample = Float(samples[index]) / Float(Int32.max)
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            if firstNonZero == nil, magnitude > 0.000_001 {
                firstNonZero = sample
            }
        }
        return (peak, firstNonZero)
    }
}

private final class SampleBufferAudioFileWriter {
    let url: URL
    var formatDescription: String?
    var lastWrittenSampleSummary: String = "No PCM buffers written"

    private var audioFile: AVAudioFile?
    private var finished = false

    init(url: URL) {
        self.url = url
    }

    func append(_ sampleBuffer: CMSampleBuffer) throws {
        let pcmBuffer = try makePCMBuffer(from: sampleBuffer)
        lastWrittenSampleSummary = Self.inspect(pcmBuffer: pcmBuffer)

        if audioFile == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: pcmBuffer.format.settings,
                commonFormat: pcmBuffer.format.commonFormat,
                interleaved: pcmBuffer.format.isInterleaved
            )
            formatDescription = "\(Int(pcmBuffer.format.sampleRate)) Hz, \(pcmBuffer.format.channelCount) ch, \(pcmBuffer.format.commonFormat)"
        }

        try audioFile?.write(from: pcmBuffer)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        audioFile = nil
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw CaptureError("Sample buffer did not contain a readable audio format.")
        }

        let formatPointer = UnsafePointer<AudioStreamBasicDescription>(streamDescription)
        guard let format = AVAudioFormat(streamDescription: formatPointer) else {
            throw CaptureError("Sample buffer did not contain a readable audio format.")
        }

        let frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw CaptureError("Unable to allocate a PCM buffer for audio capture.")
        }
        pcmBuffer.frameLength = frameLength
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        let bufferListSize = MemoryLayout<AudioBufferList>.size + max(destinationBuffers.count - 1, 0) * MemoryLayout<AudioBuffer>.size
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameLength),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            throw CaptureError("Failed to copy PCM sample buffers (OSStatus \(status), listSize \(bufferListSize)).")
        }

        for index in 0..<destinationBuffers.count {
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            destinationBuffers[index].mDataByteSize = UInt32(Int(frameLength) * max(bytesPerFrame, 1))
        }

        return pcmBuffer
    }

    private static func inspect(pcmBuffer: AVAudioPCMBuffer) -> String {
        let frameLength = Int(pcmBuffer.frameLength)
        guard frameLength > 0 else {
            return "PCM peak=0.000000 firstNonZero=none"
        }

        switch pcmBuffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = pcmBuffer.floatChannelData else {
                return "PCM peak=0.000000 firstNonZero=none"
            }
            var peak: Float = 0
            var firstNonZero: Float?
            let channelCount = Int(pcmBuffer.format.channelCount)
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = samples[frame]
                    let magnitude = abs(sample)
                    peak = max(peak, magnitude)
                    if firstNonZero == nil, magnitude > 0.000_001 {
                        firstNonZero = sample
                    }
                }
            }
            let firstText = firstNonZero.map { String(format: "%.6f", $0) } ?? "none"
            return "PCM peak=\(String(format: "%.6f", peak)) firstNonZero=\(firstText)"
        default:
            return "PCM inspection unsupported for \(pcmBuffer.format.commonFormat)"
        }
    }
}
