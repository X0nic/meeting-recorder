import Foundation
import AVFoundation
import AppKit
import CoreGraphics

@MainActor
final class AppViewModel: ObservableObject {
    @Published var phase: RecorderPhase = .idle
    @Published var processingSteps: [ProcessingStep] = [
        .init(label: "Extracting audio...", status: .pending),
        .init(label: "Transcribing (model: ggml-small.bin)...", status: .pending),
        .init(label: "Generating notes...", status: .pending)
    ]
    @Published var selectedSystemAudioID: String? {
        didSet { selectionDidChange() }
    }
    @Published var selectedMicID: String? {
        didSet { selectionDidChange() }
    }
    @Published var selectedScreenID: CGDirectDisplayID? {
        didSet { selectionDidChange() }
    }
    @Published var elapsedText = "00:00"
    @Published var transcriptWordCount: Int = 0
    @Published var latestResult: ProcessingResult?
    @Published var statusMessage = ""
    @Published var historySearch = ""
    @Published var shouldPresentFileImporter = false
    @Published var preflightBlackHoleReady = false
    @Published var preflightMappingReady = false
    @Published var preflightSystemSignalReady = false
    @Published var preflightMicSignalReady = false
    @Published var preflightSignalRunning = false

    let deviceService = AudioDeviceService()
    let meter = AudioLevelMonitor()
    let detector = MeetingDetector()
    let history = MeetingHistoryStore()

    private let recorder = RecorderService()
    private let pipeline = ProcessingPipeline()

    private var meetingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/meetings", isDirectory: true)
    }

    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?
    private var suppressSelectionChangeHandling = false

    var canStartRecording: Bool {
        preflightBlackHoleReady
            && preflightMappingReady
            && preflightSystemSignalReady
            && preflightMicSignalReady
            && !preflightSignalRunning
    }

    func onAppear() {
        Task {
            await refreshDevicesAndApps()
            refreshHistory()
            requestPermissions()
        }
    }

    func refreshDevicesAndApps() async {
        await deviceService.refresh()

        suppressSelectionChangeHandling = true
        if selectedSystemAudioID == nil {
            selectedSystemAudioID = deviceService.defaultSystemAudio()?.id
        }
        if selectedMicID == nil {
            selectedMicID = deviceService.defaultMic()?.id
        }
        if selectedScreenID == nil {
            selectedScreenID = deviceService.screenOptions.first?.displayID
        }

        detector.refresh(screenOptions: deviceService.screenOptions)
        if let recommended = detector.recommendedScreenID {
            selectedScreenID = recommended
        }
        suppressSelectionChangeHandling = false
        updateStaticPreflightChecks()
    }

    func startRecording() {
        guard canStartRecording else {
            statusMessage = "Run preflight and confirm BlackHole, mapping, and both signal checks pass."
            return
        }

        guard let config = makeConfiguration() else {
            statusMessage = "Select screen, BlackHole 2ch, and microphone first."
            return
        }

        Task {
            do {
                _ = try FileManager.default.createDirectoryIfNeeded(at: meetingsRoot)
                let folder = try await recorder.startRecording(config, meetingsRoot: meetingsRoot)
                recordingStartedAt = Date()
                startElapsedTimer()
                try meter.start(systemDeviceID: config.systemAudio.id, micDeviceID: config.microphone.id)
                phase = .recording
                statusMessage = "Recording in \(folder.lastPathComponent)"
            } catch {
                phase = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        Task {
            do {
                let folder = try await recorder.stopRecording()
                meter.stop()
                stopElapsedTimer()
                phase = .processing
                resetSteps()
                try await processMeeting(folder)
            } catch {
                phase = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
            }
        }
    }

    func processExternalFile(_ url: URL) {
        phase = .processing
        resetSteps()
        Task {
            do {
                let result = try await pipeline.processExternalFile(sourceURL: url, meetingsRoot: meetingsRoot) { [weak self] index, status in
                    Task { @MainActor in
                        guard let self, self.processingSteps.indices.contains(index) else { return }
                        self.processingSteps[index].status = status
                    }
                }
                latestResult = result
                transcriptWordCount = result.wordCount
                phase = .complete
                statusMessage = "Finished processing \(url.lastPathComponent)."
                refreshHistory()
            } catch {
                phase = .failed(error.localizedDescription)
                statusMessage = error.localizedDescription
                markRunningStepsFailed()
            }
        }
    }

    func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func refreshHistory() {
        history.refresh(root: meetingsRoot, search: historySearch)
    }

    func newRecording() {
        latestResult = nil
        transcriptWordCount = 0
        elapsedText = "00:00"
        statusMessage = ""
        phase = .idle
    }

    func presentFileImporter() {
        shouldPresentFileImporter = true
    }

    func runSignalPreflightCheck() {
        guard !preflightSignalRunning else { return }
        guard let config = makeConfiguration() else {
            statusMessage = "Select screen, BlackHole 2ch, and microphone first."
            return
        }

        preflightSignalRunning = true
        preflightSystemSignalReady = false
        preflightMicSignalReady = false
        statusMessage = "Checking audio signal for 3 seconds. Play meeting audio and speak."

        Task {
            var systemPeak: Double = 0
            var micPeak: Double = 0
            do {
                try meter.start(systemDeviceID: config.systemAudio.id, micDeviceID: config.microphone.id)
                for _ in 0..<30 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    systemPeak = max(systemPeak, meter.systemLevel)
                    micPeak = max(micPeak, meter.micLevel)
                }
                meter.stop()

                preflightSystemSignalReady = systemPeak > 0.03
                preflightMicSignalReady = micPeak > 0.03
                preflightSignalRunning = false
                if preflightSystemSignalReady && preflightMicSignalReady {
                    statusMessage = "Signal check passed for system audio and microphone."
                } else {
                    statusMessage = "Signal check failed. Ensure BlackHole routing is active and retry."
                }
            } catch {
                meter.stop()
                preflightSignalRunning = false
                statusMessage = "Signal check failed: \(error.localizedDescription)"
            }
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    private func selectionDidChange() {
        guard !suppressSelectionChangeHandling else { return }
        updateStaticPreflightChecks()
        preflightSystemSignalReady = false
        preflightMicSignalReady = false
    }

    private func updateStaticPreflightChecks() {
        let hasBlackHole = deviceService.audioDevices.contains(where: \.isBlackHole)
        let selectedSystem = deviceService.audioDevices.first(where: { $0.id == selectedSystemAudioID })
        preflightBlackHoleReady = hasBlackHole && (selectedSystem?.isBlackHole == true)

        if let config = makeConfiguration() {
            preflightMappingReady = config.screen.ffmpegIndex != nil
                && config.systemAudio.avFoundationIndex != nil
                && config.microphone.avFoundationIndex != nil
        } else {
            preflightMappingReady = false
        }
    }

    private func makeConfiguration() -> RecordingConfiguration? {
        guard let screenID = selectedScreenID,
              let systemID = selectedSystemAudioID,
              let micID = selectedMicID,
              let screen = deviceService.screenOptions.first(where: { $0.displayID == screenID }),
              let system = deviceService.audioDevices.first(where: { $0.id == systemID }),
              let mic = deviceService.audioDevices.first(where: { $0.id == micID }) else {
            return nil
        }
        return RecordingConfiguration(screen: screen, systemAudio: system, microphone: mic)
    }

    private func processMeeting(_ folder: URL) async throws {
        do {
            let result = try await pipeline.processMeeting(folder: folder) { [weak self] index, status in
                Task { @MainActor in
                    guard let self, self.processingSteps.indices.contains(index) else { return }
                    self.processingSteps[index].status = status
                }
            }
            latestResult = result
            transcriptWordCount = result.wordCount
            phase = .complete
            statusMessage = "Meeting notes generated."
            refreshHistory()
        } catch {
            markRunningStepsFailed()
            throw error
        }
    }

    private func resetSteps() {
        for index in processingSteps.indices {
            processingSteps[index].status = .pending
        }
    }

    private func markRunningStepsFailed() {
        for index in processingSteps.indices where processingSteps[index].status == .running {
            processingSteps[index].status = .failed
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            let elapsed = Int(Date().timeIntervalSince(started))
            let mins = elapsed / 60
            let secs = elapsed % 60
            self.elapsedText = String(format: "%02d:%02d", mins, secs)
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
    }

}

private extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws -> URL {
        try createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }
}
