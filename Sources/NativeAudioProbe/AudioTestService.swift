@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class AudioTestService: NSObject, ObservableObject {
    @Published private(set) var runState: ProbeRunState = .idle
    @Published private(set) var permissions = PermissionSnapshot()
    @Published private(set) var systemAudioLevel: Float = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var statusEvents: [ProbeStatusEvent] = []
    @Published private(set) var backendStatus = "ScreenCaptureKit backend idle"
    @Published private(set) var backendVerdict: BackendVerdict = .pending
    @Published private(set) var lastError: String?
    @Published private(set) var outputPaths: ProbeOutputPaths?
    @Published private(set) var streamStarted = false
    @Published private(set) var didReceiveSystemAudio = false
    @Published private(set) var didReceiveMicrophoneAudio = false
    @Published private(set) var systemAudioFormat = "Not started"
    @Published private(set) var microphoneAudioFormat = "Not started"
    @Published var selectedMicrophoneID: String = ""

    private(set) var microphones: [AudioDeviceOption] = []

    private let systemQueue = DispatchQueue(label: "NativeAudioProbe.system-audio")
    private let microphoneQueue = DispatchQueue(label: "NativeAudioProbe.microphone")

    private var stream: SCStream?
    private var timeoutTask: Task<Void, Never>?
    private let systemProcessor: StreamProcessor
    private let microphoneProcessor: StreamProcessor

    override init() {
        let systemProcessor = StreamProcessor(streamType: .audio)
        let microphoneProcessor = StreamProcessor(streamType: .microphone)
        self.systemProcessor = systemProcessor
        self.microphoneProcessor = microphoneProcessor
        super.init()
        refreshMicrophones()
        if let firstMicrophone = microphones.first {
            selectedMicrophoneID = firstMicrophone.id
        }
        refreshPermissions()

        systemProcessor.eventHandler = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.apply(update)
            }
        }
        microphoneProcessor.eventHandler = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.apply(update)
            }
        }
    }

    func initialize() {
        refreshMicrophones()
        refreshPermissions()
        log("App ready")
        log("Initial permissions: screen=\(permissions.screenRecording.rawValue), mic=\(permissions.microphone.rawValue)")
        if microphones.isEmpty {
            log("No microphone devices were discovered")
        } else {
            log("Discovered \(microphones.count) microphone device(s)")
        }
    }

    func refreshMicrophones() {
        microphones = AVCaptureDevice
            .DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices
            .map { AudioDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func refreshPermissions() {
        permissions.screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissions.microphone = .granted
        case .denied, .restricted:
            permissions.microphone = .denied
        case .notDetermined:
            permissions.microphone = .notDetermined
        @unknown default:
            permissions.microphone = .unavailable
        }
    }

    func startTest() async {
        guard runState != .starting, runState != .running else { return }

        runState = .starting
        backendStatus = "Preparing ScreenCaptureKit audio-only test"
        lastError = nil
        systemAudioLevel = 0
        microphoneLevel = 0
        streamStarted = false
        didReceiveSystemAudio = false
        didReceiveMicrophoneAudio = false
        backendVerdict = .pending
        systemAudioFormat = "Waiting for frames"
        microphoneAudioFormat = "Waiting for frames"
        statusEvents.removeAll()
        outputPaths = nil

        log("Backend selected: ScreenCaptureKit single-stream audio + microphone")
        refreshPermissions()
        log("Permissions state: screen=\(permissions.screenRecording.rawValue), mic=\(permissions.microphone.rawValue)")

        do {
            try await requestPermissionsIfNeeded()
            let paths = try createOutputPaths()
            outputPaths = paths
            log("Output folder ready: \(paths.folderURL.path)")
            systemProcessor.prepare(url: paths.systemAudioURL)
            microphoneProcessor.prepare(url: paths.microphoneAudioURL)

            let shareableContent = try await SCShareableContent.current
            guard let display = shareableContent.displays.first else {
                throw NSError(domain: "NativeAudioProbe", code: 10, userInfo: [NSLocalizedDescriptionKey: "No shareable display was available for the ScreenCaptureKit stream."])
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
            if !selectedMicrophoneID.isEmpty {
                configuration.microphoneCaptureDeviceID = selectedMicrophoneID
            }

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try addOutput(stream, type: .audio, queue: systemQueue)
            try addOutput(stream, type: .microphone, queue: microphoneQueue)
            log("Stream outputs attached")

            self.stream = stream
            try await startCapture(stream)

            streamStarted = true
            runState = .running
            backendStatus = "Stream started, waiting for audio frames"
            log("Stream started")
            startFrameTimeout()
        } catch {
            handleFailure(error)
        }
    }

    func requestPermissionsOnly() async {
        lastError = nil
        log("Permission check started")

        do {
            try await requestPermissionsIfNeeded()
            backendStatus = "Permissions granted"
            log("Permission check completed")
        } catch {
            handleFailure(error)
        }
    }

    func stopTest() async {
        guard runState == .running || runState == .starting else { return }

        runState = .stopping
        backendStatus = "Stopping capture"
        timeoutTask?.cancel()
        timeoutTask = nil

        do {
            if let stream {
                try await stopCapture(stream)
            }
            systemProcessor.finish()
            microphoneProcessor.finish()
            self.stream = nil
            runState = .idle
            backendStatus = captureSummaryStatus()
            log("Stream stopped")
        } catch {
            handleFailure(error)
        }
    }

    func openOutputFolder() {
        guard let folderURL = outputPaths?.folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private func requestPermissionsIfNeeded() async throws {
        if !CGPreflightScreenCaptureAccess() {
            log("Requesting screen recording permission")
            let granted = CGRequestScreenCaptureAccess()
            refreshPermissions()
            log("Screen recording request result: \(granted ? "granted" : "not granted")")
            if !granted {
                throw NSError(domain: "NativeAudioProbe", code: 11, userInfo: [NSLocalizedDescriptionKey: "Screen recording permission was not granted."])
            }
        }

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            log("Requesting microphone permission")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
            log("Microphone request result: \(granted ? "granted" : "not granted")")
        } else {
            refreshPermissions()
        }

        guard permissions.microphone == .granted else {
            throw NSError(domain: "NativeAudioProbe", code: 12, userInfo: [NSLocalizedDescriptionKey: "Microphone permission was not granted."])
        }
    }

    private func createOutputPaths() throws -> ProbeOutputPaths {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let folderName = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-recorder-audio-probe", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        return ProbeOutputPaths(
            folderURL: folderURL,
            systemAudioURL: folderURL.appendingPathComponent("system-audio.caf"),
            microphoneAudioURL: folderURL.appendingPathComponent("mic-audio.caf")
        )
    }

    private func addOutput(_ stream: SCStream, type: SCStreamOutputType, queue: DispatchQueue) throws {
        do {
            try stream.addStreamOutput(self, type: type, sampleHandlerQueue: queue)
        } catch {
            throw NSError(domain: "NativeAudioProbe", code: 13, userInfo: [NSLocalizedDescriptionKey: "Could not attach \(String(describing: type)) output: \(error.localizedDescription)"])
        }
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func stopCapture(_ stream: SCStream) async throws {
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

    private func startFrameTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            if self.runState == .running && !self.didReceiveSystemAudio {
                self.backendVerdict = .nonViable
                self.backendStatus = "Stream started but no system-audio frames arrived"
                self.log("Failure point: stream started but no system-audio frames arrived within 5 seconds")
            }
            if self.runState == .running && !self.didReceiveMicrophoneAudio {
                self.log("Diagnostic: stream started but no microphone frames arrived within 5 seconds")
            }
        }
    }

    private func handleFailure(_ error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        runState = .failed
        backendVerdict = .nonViable
        backendStatus = "Capture failed"
        lastError = error.localizedDescription
        systemProcessor.finish()
        microphoneProcessor.finish()
        stream = nil
        log("Error: \(error.localizedDescription)")
    }

    private func log(_ message: String) {
        statusEvents.append(ProbeStatusEvent(timestamp: Date(), message: message))
    }

    private func captureSummaryStatus() -> String {
        if didReceiveSystemAudio && didReceiveMicrophoneAudio {
            backendVerdict = .viable
            return "Capture complete: both audio streams received"
        }
        if streamStarted && !didReceiveSystemAudio {
            backendVerdict = .nonViable
            return "Capture complete: no system-audio frames received"
        }
        return "Capture stopped"
    }

    private func apply(_ update: ProcessedAudioUpdate) {
        if let message = update.eventMessage {
            log(message)
        }
        if let formatDescription = update.formatDescription {
            switch update.type {
            case .audio:
                systemAudioFormat = formatDescription
            case .microphone:
                microphoneAudioFormat = formatDescription
            case .screen:
                break
            @unknown default:
                break
            }
        }
        if let errorDescription = update.errorDescription {
            handleFailure(NSError(domain: "NativeAudioProbe", code: 20, userInfo: [NSLocalizedDescriptionKey: errorDescription]))
            return
        }

        switch update.type {
        case .audio:
            if let level = update.level {
                systemAudioLevel = AudioMeter.smoothedLevel(previous: systemAudioLevel, incoming: level)
            }
            if update.didReceiveFirstFrame {
                didReceiveSystemAudio = true
                if didReceiveMicrophoneAudio {
                    backendVerdict = .viable
                    backendStatus = "Both audio streams are receiving frames"
                } else {
                    backendStatus = "System-audio frames received"
                }
                log("First system-audio frame received")
            }
        case .microphone:
            if let level = update.level {
                microphoneLevel = AudioMeter.smoothedLevel(previous: microphoneLevel, incoming: level)
            }
            if update.didReceiveFirstFrame {
                didReceiveMicrophoneAudio = true
                if didReceiveSystemAudio {
                    backendVerdict = .viable
                    backendStatus = "Both audio streams are receiving frames"
                } else {
                    backendStatus = "Microphone frames received"
                }
                log("First microphone frame received")
            }
        case .screen:
            break
        @unknown default:
            break
        }
    }
}

extension AudioTestService: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleFailure(error)
        }
    }
}

extension AudioTestService: SCStreamOutput {
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
            break
        @unknown default:
            break
        }
    }
}

private struct ProcessedAudioUpdate: Sendable {
    let type: SCStreamOutputType
    let level: Float?
    let formatDescription: String?
    let eventMessage: String?
    let errorDescription: String?
    let didReceiveFirstFrame: Bool
}

private final class StreamProcessor: @unchecked Sendable {
    let streamType: SCStreamOutputType
    var eventHandler: (@Sendable (ProcessedAudioUpdate) -> Void)?

    private let lock = NSLock()
    private var writer: AudioFileWriter?
    private var didReceiveFirstFrame = false

    init(streamType: SCStreamOutputType) {
        self.streamType = streamType
    }

    func prepare(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        didReceiveFirstFrame = false
        writer = AudioFileWriter(url: url) { [weak self] message in
            guard let self else { return }
            self.eventHandler?(ProcessedAudioUpdate(type: self.streamType, level: nil, formatDescription: nil, eventMessage: message, errorDescription: nil, didReceiveFirstFrame: false))
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
        guard let writer else {
            lock.unlock()
            return
        }

        do {
            _ = try writer.append(sampleBuffer)
            let level = AudioMeter.normalizedLevel(from: sampleBuffer)
            let formatDescription = writer.formatDescription
            let isFirstFrame = !didReceiveFirstFrame
            if isFirstFrame {
                didReceiveFirstFrame = true
            }
            lock.unlock()

            eventHandler?(ProcessedAudioUpdate(
                type: streamType,
                level: level,
                formatDescription: formatDescription,
                eventMessage: nil,
                errorDescription: nil,
                didReceiveFirstFrame: isFirstFrame
            ))
        } catch {
            lock.unlock()
            eventHandler?(ProcessedAudioUpdate(
                type: streamType,
                level: nil,
                formatDescription: nil,
                eventMessage: nil,
                errorDescription: error.localizedDescription,
                didReceiveFirstFrame: false
            ))
        }
    }
}
