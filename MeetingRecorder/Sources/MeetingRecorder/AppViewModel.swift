import Foundation
import AVFoundation
import AppKit
import ScreenCaptureKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var phase: RecorderPhase = .idle
    @Published var processingSteps: [ProcessingStep] = [
        .init(label: "Extracting audio...", status: .pending),
        .init(label: "Transcribing (model: ggml-small.bin)...", status: .pending),
        .init(label: "Generating notes...", status: .pending)
    ]
    @Published var selectedSystemAudioID: String?
    @Published var selectedMicID: String?
    @Published var selectedScreenID: CGDirectDisplayID?
    @Published var elapsedText = "00:00"
    @Published var transcriptWordCount: Int = 0
    @Published var latestResult: ProcessingResult?
    @Published var statusMessage = ""
    @Published var historySearch = ""
    @Published var shouldPresentFileImporter = false

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

    func onAppear() {
        Task {
            await refreshDevicesAndApps()
            refreshHistory()
            requestPermissions()
        }
    }

    func refreshDevicesAndApps() async {
        await deviceService.refresh()

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
    }

    func startRecording() {
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

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        Task {
            try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
