import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var audioLevels = AudioLevels()
    @Published var detectedMeetings: [MeetingAppPresence] = []
    @Published var selectedMeeting: MeetingAppPresence?
    @Published var micDevice: AudioInputDevice?
    @Published var permissionDiagnostics = PermissionDiagnostics()
    @Published var availableWhisperModels: [WhisperModelInfo] = []
    @Published var selectedWhisperModel: WhisperModelInfo?
    @Published var processingSteps: [String] = []
    @Published var errorMessage: String?
    @Published var setupMessage: String?
    @Published var captureBackendState = AudioCaptureBackendState.idle
    @Published var history: [MeetingRecord] = []
    @Published var historySearchText = ""
    @Published var isFileImporterPresented = false
    @Published var isMeetingFolderImporterPresented = false
    @Published var lastCompletedSummary: RecordingSessionSummary?
    @Published var isMonitoringAudio = false
    @Published var isGeneratingNotes = false

    private let detector = MeetingDetector()
    private let audioCaptureBackend: MeetingAudioCaptureBackend = ScreenCaptureKitAudioCaptureService()
    private let store = MeetingStore.shared
    private lazy var pipeline = ProcessingPipeline(store: store)
    private let defaults = UserDefaults.standard

    private var recordingStartedAt: Date?
    private var sessionDirectoryURL: URL?
    private var displayRefreshTimer: Timer?
    private var monitorRefreshTask: Task<Void, Never>?
    private static let savedMicDeviceIDKey = "meetingRecorder.savedMicDeviceID"
    private static let savedMeetingBundleIDKey = "meetingRecorder.savedMeetingBundleID"
    private static let savedMeetingNameKey = "meetingRecorder.savedMeetingName"

    init() {
        audioCaptureBackend.delegate = self
    }

    var canStartRecording: Bool {
        selectedMeeting != nil && micDevice != nil
    }

    var availableMicDevices: [AudioInputDevice] {
        MicrophoneDeviceCatalog.availableMicrophones()
    }

    var phaseSubtitle: String {
        switch phase {
        case .idle:
            return "ScreenCaptureKit raw system audio + microphone capture"
        case .recording:
            return "Capturing raw system audio and mic"
        case .processing:
            return "Mixing audio, transcribing, and generating notes"
        case .complete:
            return "Latest capture saved to Documents/meetings"
        case .failed:
            return "Fix the capture error and try again"
        }
    }

    var elapsedRecordingTimeText: String {
        guard let recordingStartedAt else { return "00:00" }
        return formatDuration(Date().timeIntervalSince(recordingStartedAt))
    }

    var recordingStatusLine: String {
        if phase == .failed, let captureFailureBannerMessage {
            return captureFailureBannerMessage
        }
        if let selectedMeeting {
            let title = selectedMeeting.windowTitle.map { " - \($0)" } ?? ""
            return phase == .recording ? "Recording \(selectedMeeting.appName)\(title)" : "Target app: \(selectedMeeting.appName)\(title)"
        }
        return "Target app: Select a meeting app"
    }

    var audioMonitorStatusLine: String {
        if !isMonitoringAudio {
            return "Audio monitor is offline"
        }
        let systemReady = captureBackendState.didReceiveSystemAudio || audioLevels.system > 0.02
        let micReady = captureBackendState.didReceiveMicrophoneAudio || audioLevels.mic > 0.02
        let appText = systemReady ? "System audio detected" : "Play audio in the selected meeting"
        let micText = micReady ? "Mic detected" : "Speak to test microphone"
        return "\(appText) • \(micText)"
    }

    var microphoneActivityText: String {
        audioLevels.mic > 0.02 ? "Mic signal detected" : "Speak now to verify the selected microphone"
    }

    var systemAudioActivityText: String {
        audioLevels.system > 0.02 ? "System audio detected" : "Play meeting audio to verify ScreenCaptureKit capture"
    }

    var captureOutputSummaryText: String {
        if phase == .recording {
            return "Writing separate raw files for system audio and microphone."
        }
        return "Raw CAF files stay available for debugging alongside the mixed audio, transcript, and notes."
    }

    var captureFailureBannerMessage: String? {
        guard let failurePoint = captureBackendState.failurePoint else {
            return nil
        }
        let status = captureBackendState.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = status.isEmpty ? "ScreenCaptureKit capture stopped unexpectedly." : status

        if failurePoint.hasPrefix("waiting-for-") {
            return "Recording is not active. \(detail)"
        }
        if failurePoint.hasPrefix("processing-") || failurePoint == "stream-did-stop" {
            return "Recording failed and has stopped. \(detail)"
        }
        return "Recording could not continue. \(detail)"
    }

    var processingProgress: Double {
        let currentStage = processingStage
        guard currentStage.total > 0 else { return 0 }
        return Double(currentStage.completed) / Double(currentStage.total)
    }

    var processingProgressLabel: String? {
        let currentStage = processingStage
        guard currentStage.total > 0 else { return nil }
        return "\(currentStage.completed) of \(currentStage.total) steps"
    }

    private var processingStage: (completed: Int, total: Int, current: String?) {
        let total = 4
        guard let currentStep = processingSteps.last else {
            return (phase == .complete ? total : 0, total, nil)
        }

        if currentStep.hasPrefix("Stopping capture") {
            return (1, total, "Stopping capture...")
        }
        if currentStep.hasPrefix("Mixing audio") {
            return (2, total, "Mixing audio...")
        }
        if currentStep.hasPrefix("Transcribing") {
            return (3, total, currentStep)
        }
        if currentStep.hasPrefix("Generating notes") {
            return (4, total, "Generating notes...")
        }
        if phase == .complete {
            return (total, total, "Complete")
        }

        return (0, total, currentStep)
    }

    func initialize() async {
        refreshEnvironment()
        refreshHistory()
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshEnvironment()
            }
        }
    }

    func refreshEnvironment() {
        detectedMeetings = detector.detectMeetings()
        applySavedMeetingSelection()
        applySavedMicrophoneSelection(from: availableMicDevices)
        updatePermissionDiagnostics()

        availableWhisperModels = pipeline.discoverWhisperModels()
        if selectedWhisperModel == nil {
            selectedWhisperModel = availableWhisperModels.first(where: { $0.sizeName == "small" }) ?? availableWhisperModels.first
        }

        refreshAudioMonitoring()
    }

    func toggleRecording() {
        if phase == .recording {
            Task {
                await stopRecording()
            }
        } else {
            Task {
                await startRecording()
            }
        }
    }

    func startRecording() async {
        guard selectedMeeting != nil, let micDevice else {
            errorMessage = "Select a meeting app and microphone before recording."
            phase = .failed
            return
        }

        do {
            monitorRefreshTask?.cancel()
            await audioCaptureBackend.stopMonitoring()
            errorMessage = nil
            processingSteps = []
            let directory = try await store.createSessionDirectory()
            sessionDirectoryURL = directory
            recordingStartedAt = .now
            try await audioCaptureBackend.startRecording(micDeviceID: micDevice.id, in: directory)
            setupMessage = nil
            isMonitoringAudio = false
            phase = .recording
            updatePermissionDiagnostics()
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard phase == .recording else { return }
        phase = .processing
        processingSteps = ["Stopping capture..."]

        do {
            var artifacts = try await audioCaptureBackend.stopRecording()
            processingSteps = ["Stopping capture...", "Mixing audio..."]
            let mixedAudioURL = try mixRecordedAudio(artifacts: artifacts)
            artifacts.mixedAudioURL = mixedAudioURL
            let summary = try await runProcessingForRecordedAudio(artifacts: artifacts, audioURL: mixedAudioURL)
            lastCompletedSummary = summary
            phase = .complete
            processingSteps = completedSteps(for: summary)
            if let notesErrorDescription = summary.notesErrorDescription {
                errorMessage = "Note generation failed: \(notesErrorDescription)"
            }
            refreshAudioMonitoring()
            refreshHistory()
        } catch {
            phase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func processImportedFile(url: URL) {
        Task {
            do {
                errorMessage = nil
                phase = .processing
                processingSteps = ["Importing file..."]
                let directory = try await store.createSessionDirectory()
                sessionDirectoryURL = directory
                let importedAudio = try await pipeline.importAudioTrack(from: url, into: directory)
                recordingStartedAt = .now
                let summary = try await runProcessingForImportedAudio(audioURL: importedAudio)
                phase = .complete
                lastCompletedSummary = summary
                processingSteps = completedSteps(for: summary)
                if let notesErrorDescription = summary.notesErrorDescription {
                    errorMessage = "Note generation failed: \(notesErrorDescription)"
                }
                refreshAudioMonitoring()
                refreshHistory()
            } catch {
                phase = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    func handleFileImport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            processImportedFile(url: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func reprocessMeetingFolder(url: URL) {
        Task {
            do {
                errorMessage = nil
                phase = .processing
                processingSteps = ["Loading meeting folder...", "Mixing audio..."]

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw NSError(domain: "AppModel", code: 70, userInfo: [NSLocalizedDescriptionKey: "Select a meeting folder, not a file."])
                }

                sessionDirectoryURL = url
                let existingMetadata = try? await store.loadMetadata(in: url)
                let artifacts = try resolveExistingArtifacts(in: url, metadata: existingMetadata)
                let mixedAudioURL = try mixRecordedAudio(artifacts: artifacts)
                let measuredDuration = try duration(of: mixedAudioURL)
                let summary = try await runProcessingForReprocessedAudio(
                    directory: url,
                    artifacts: artifacts,
                    audioURL: mixedAudioURL,
                    existingMetadata: existingMetadata,
                    measuredDuration: measuredDuration
                )

                lastCompletedSummary = summary
                phase = .complete
                processingSteps = completedSteps(for: summary)
                if let notesErrorDescription = summary.notesErrorDescription {
                    errorMessage = "Note generation failed: \(notesErrorDescription)"
                }
                refreshAudioMonitoring()
                refreshHistory()
            } catch {
                phase = .failed
                errorMessage = error.localizedDescription
            }
        }
    }

    func handleMeetingFolderImport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            reprocessMeetingFolder(url: url)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func refreshHistory() {
        Task {
            let records = await store.loadHistory(searchTerm: historySearchText)
            await MainActor.run {
                self.history = records
            }
        }
    }

    func openMeetingsFolder() {
        open(url: store.meetingsDirectory)
    }

    func generateNotes(for meeting: MeetingRecord) {
        Task {
            await regenerateNotes(in: meeting.directoryURL, transcriptURL: meeting.transcriptURL)
        }
    }

    func generateNotesForLastSummary() {
        guard let summary = lastCompletedSummary else { return }
        Task {
            await regenerateNotes(in: summary.directoryURL, transcriptURL: summary.transcriptURL)
        }
    }

    func refreshAudioMonitoring() {
        guard phase != .recording && phase != .processing else { return }
        monitorRefreshTask?.cancel()

        guard selectedMeeting != nil, let micDevice else {
            monitorRefreshTask = Task {
                await audioCaptureBackend.stopMonitoring()
            }
            isMonitoringAudio = false
            updatePermissionDiagnostics()
            return
        }

        monitorRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.audioCaptureBackend.startMonitoring(micDeviceID: micDevice.id)
                self.isMonitoringAudio = true
                if self.setupMessage == nil {
                    self.setupMessage = "ScreenCaptureKit monitoring is live. Play meeting audio and speak into the mic to verify both meters."
                }
                self.updatePermissionDiagnostics()
            } catch {
                self.isMonitoringAudio = false
                if self.errorMessage == nil {
                    self.errorMessage = error.localizedDescription
                }
                self.updatePermissionDiagnostics()
            }
        }
    }

    func selectMeetingApp(id: String) {
        selectedMeeting = detectedMeetings.first(where: { $0.id == id })
        defaults.set(selectedMeeting?.bundleID, forKey: Self.savedMeetingBundleIDKey)
        defaults.set(selectedMeeting?.appName, forKey: Self.savedMeetingNameKey)
        setupMessage = "Meeting app updated. ScreenCaptureKit will capture system audio while this app remains the selected meeting target."
        refreshEnvironment()
    }

    func selectMicDevice(id: String) {
        let devices = availableMicDevices
        micDevice = devices.first(where: { $0.id == id })
        defaults.set(id, forKey: Self.savedMicDeviceIDKey)
        setupMessage = "Microphone updated. Speak now to verify the selected input."
        refreshEnvironment()
    }

    func runMicrophoneTest() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            await MainActor.run {
                self.permissionDiagnostics.microphone = self.microphonePermissionStatus()
                self.setupMessage = "Testing microphone. Speak now and watch the microphone meter."
                self.refreshEnvironment()
            }
        }
    }

    func runMeetingAudioTest() {
        setupMessage = "Testing ScreenCaptureKit system audio capture. Play meeting audio and watch the system audio meter."
        refreshEnvironment()
    }

    func openMicrophoneSettings() {
        openSystemSettings(anchor: "Privacy_Microphone")
    }

    func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: duration) ?? "00:00"
    }
}

extension AppModel: AudioCaptureBackendDelegate {
    nonisolated func audioCaptureBackend(didUpdateLevels levels: AudioLevels) {
        Task { @MainActor in
            self.audioLevels = levels
        }
    }

    nonisolated func audioCaptureBackend(didUpdateState state: AudioCaptureBackendState) {
        Task { @MainActor in
            self.captureBackendState = state
            if self.phase != .recording {
                self.isMonitoringAudio = state.streamStarted
            }
            if self.phase == .recording, let activeFailureMessage = self.captureFailureBannerMessage {
                self.phase = .failed
                self.isMonitoringAudio = false
                self.errorMessage = activeFailureMessage
                self.setupMessage = "The capture backend stopped. Fix the issue below before starting a new recording."
                self.audioLevels = AudioLevels()
            }
            self.updatePermissionDiagnostics()
        }
    }
}

private extension AppModel {
    func mixRecordedAudio(artifacts: CaptureSessionArtifacts) throws -> URL {
        guard let directory = sessionDirectoryURL else {
            throw NSError(domain: "AppModel", code: 50, userInfo: [NSLocalizedDescriptionKey: "Recording session metadata is incomplete."])
        }

        let outputURL = directory.appendingPathComponent("audio.wav")
        do {
            return try pipeline.mixRecordedAudio(
                systemAudioURL: artifacts.systemAudioURL,
                microphoneAudioURL: artifacts.microphoneAudioURL,
                outputURL: outputURL
            )
        } catch {
            throw NSError(domain: "AppModel", code: 51, userInfo: [NSLocalizedDescriptionKey: "Audio mixing failed: \(error.localizedDescription)"])
        }
    }

    func runProcessingForRecordedAudio(artifacts: CaptureSessionArtifacts, audioURL: URL) async throws -> RecordingSessionSummary {
        guard let directory = sessionDirectoryURL else {
            throw NSError(domain: "AppModel", code: 52, userInfo: [NSLocalizedDescriptionKey: "Recording session metadata is incomplete."])
        }

        let result = try await processAudio(audioURL: audioURL, initialSteps: ["Stopping capture...", "Mixing audio..."])
        let metadata = MeetingMetadata(
            createdAt: result.startedAt,
            duration: result.duration,
            wordCount: result.wordCount,
            targetAppName: selectedMeeting?.appName,
            audioCaptureMode: captureBackendState.backendKind,
            micDevice: micDevice?.name,
            displayName: nil,
            whisperModel: selectedWhisperModel?.id,
            summaryPreview: result.summaryPreview,
            recordingFileName: nil,
            audioFileName: audioURL.lastPathComponent,
            systemAudioFileName: artifacts.systemAudioURL?.lastPathComponent,
            microphoneAudioFileName: artifacts.microphoneAudioURL?.lastPathComponent,
            transcriptFileName: result.transcriptURL?.lastPathComponent,
            notesFileName: result.notesURL?.lastPathComponent
        )
        try await store.saveMetadata(metadata, in: directory)

        return RecordingSessionSummary(
            directoryURL: directory,
            recordingURL: nil,
            audioURL: audioURL,
            systemAudioURL: artifacts.systemAudioURL,
            microphoneAudioURL: artifacts.microphoneAudioURL,
            transcriptURL: result.transcriptURL,
            notesURL: result.notesURL,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            duration: result.duration,
            wordCount: result.wordCount,
            targetAppName: metadata.targetAppName,
            audioCaptureMode: metadata.audioCaptureMode?.rawValue,
            micDevice: micDevice?.name,
            whisperModel: selectedWhisperModel?.id,
            summaryPreview: result.summaryPreview,
            notesErrorDescription: result.notesErrorDescription
        )
    }

    func runProcessingForImportedAudio(audioURL: URL) async throws -> RecordingSessionSummary {
        guard let directory = sessionDirectoryURL else {
            throw NSError(domain: "AppModel", code: 53, userInfo: [NSLocalizedDescriptionKey: "Imported processing session is incomplete."])
        }

        let result = try await processAudio(audioURL: audioURL, initialSteps: ["Importing file..."])
        let metadata = MeetingMetadata(
            createdAt: result.startedAt,
            duration: result.duration,
            wordCount: result.wordCount,
            targetAppName: nil,
            audioCaptureMode: .importedFile,
            micDevice: nil,
            displayName: nil,
            whisperModel: selectedWhisperModel?.id,
            summaryPreview: result.summaryPreview,
            recordingFileName: nil,
            audioFileName: audioURL.lastPathComponent,
            systemAudioFileName: nil,
            microphoneAudioFileName: nil,
            transcriptFileName: result.transcriptURL?.lastPathComponent,
            notesFileName: result.notesURL?.lastPathComponent
        )
        try await store.saveMetadata(metadata, in: directory)

        return RecordingSessionSummary(
            directoryURL: directory,
            recordingURL: nil,
            audioURL: audioURL,
            systemAudioURL: nil,
            microphoneAudioURL: nil,
            transcriptURL: result.transcriptURL,
            notesURL: result.notesURL,
            startedAt: result.startedAt,
            endedAt: result.endedAt,
            duration: result.duration,
            wordCount: result.wordCount,
            targetAppName: nil,
            audioCaptureMode: metadata.audioCaptureMode?.rawValue,
            micDevice: nil,
            whisperModel: selectedWhisperModel?.id,
            summaryPreview: result.summaryPreview,
            notesErrorDescription: result.notesErrorDescription
        )
    }

    func processAudio(audioURL: URL, initialSteps: [String]) async throws -> ProcessedSessionResult {
        var transcriptURL: URL?
        var notesURL: URL?
        var summaryPreview = initialSteps.first == "Importing file..."
            ? "Imported audio saved."
            : "Mixed audio and raw captures are available."
        var wordCount = 0
        var notesErrorDescription: String?

        if let selectedWhisperModel {
            processingSteps = initialSteps + ["Transcribing (model: \(selectedWhisperModel.id))..."]
            do {
                transcriptURL = try await pipeline.transcribe(audioURL: audioURL, model: selectedWhisperModel)
            } catch {
                throw NSError(domain: "AppModel", code: 62, userInfo: [NSLocalizedDescriptionKey: "Transcription failed: \(error.localizedDescription)"])
            }
            if let transcriptURL {
                let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                wordCount = transcript.split(whereSeparator: \.isWhitespace).count
                summaryPreview = initialSteps.first == "Importing file..."
                    ? "Imported audio transcript is ready."
                    : "Mixed audio, raw captures, and transcript are available."
            }
        }

        if let transcriptURL {
            processingSteps = initialSteps + [
                "Transcribing (model: \(selectedWhisperModel?.id ?? "none"))...",
                "Generating notes..."
            ]
            do {
                notesURL = try await pipeline.generateNotes(transcriptURL: transcriptURL)
            } catch {
                notesErrorDescription = error.localizedDescription
                processingSteps.append("Note generation failed: \(error.localizedDescription)")
            }
            if let notesURL {
                let notes = try String(contentsOf: notesURL, encoding: .utf8)
                summaryPreview = notes
                    .split(separator: "\n")
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") })
                    .map(String.init)
                    ?? summaryPreview
            }
        }

        let endedAt = Date()
        let startedAt = recordingStartedAt ?? endedAt

        return ProcessedSessionResult(
            startedAt: startedAt,
            endedAt: endedAt,
            duration: endedAt.timeIntervalSince(startedAt),
            wordCount: wordCount,
            transcriptURL: transcriptURL,
            notesURL: notesURL,
            summaryPreview: summaryPreview,
            notesErrorDescription: notesErrorDescription
        )
    }

    func runProcessingForReprocessedAudio(
        directory: URL,
        artifacts: CaptureSessionArtifacts,
        audioURL: URL,
        existingMetadata: MeetingMetadata?,
        measuredDuration: TimeInterval
    ) async throws -> RecordingSessionSummary {
        let result = try await processAudio(audioURL: audioURL, initialSteps: ["Loading meeting folder...", "Mixing audio..."])
        let createdAt = existingMetadata?.createdAt ?? inferredCreatedAt(for: directory)
        let metadata = MeetingMetadata(
            createdAt: createdAt,
            duration: measuredDuration,
            wordCount: result.wordCount,
            targetAppName: existingMetadata?.targetAppName,
            audioCaptureMode: existingMetadata?.audioCaptureMode ?? .screenCaptureKit,
            micDevice: existingMetadata?.micDevice,
            displayName: existingMetadata?.displayName,
            whisperModel: selectedWhisperModel?.id ?? existingMetadata?.whisperModel,
            summaryPreview: result.summaryPreview,
            recordingFileName: existingMetadata?.recordingFileName,
            audioFileName: audioURL.lastPathComponent,
            systemAudioFileName: artifacts.systemAudioURL?.lastPathComponent,
            microphoneAudioFileName: artifacts.microphoneAudioURL?.lastPathComponent,
            transcriptFileName: result.transcriptURL?.lastPathComponent,
            notesFileName: result.notesURL?.lastPathComponent
        )
        try await store.saveMetadata(metadata, in: directory)

        return RecordingSessionSummary(
            directoryURL: directory,
            recordingURL: existingMetadata?.recordingFileName.map { directory.appendingPathComponent($0) },
            audioURL: audioURL,
            systemAudioURL: artifacts.systemAudioURL,
            microphoneAudioURL: artifacts.microphoneAudioURL,
            transcriptURL: result.transcriptURL,
            notesURL: result.notesURL,
            startedAt: createdAt,
            endedAt: result.endedAt,
            duration: measuredDuration,
            wordCount: result.wordCount,
            targetAppName: metadata.targetAppName ?? metadata.displayName,
            audioCaptureMode: metadata.audioCaptureMode?.rawValue,
            micDevice: metadata.micDevice,
            whisperModel: metadata.whisperModel,
            summaryPreview: result.summaryPreview,
            notesErrorDescription: result.notesErrorDescription
        )
    }

    func completedSteps(for summary: RecordingSessionSummary) -> [String] {
        var steps = [
            "Stopping capture...",
            "Mixing audio...",
            "Created \(summary.audioURL?.lastPathComponent ?? "audio.wav")"
        ]

        if let whisperModel = summary.whisperModel, summary.transcriptURL != nil {
            steps.append("Transcribing (model: \(whisperModel))...")
        }
        if summary.notesURL != nil {
            steps.append("Generating notes...")
        }
        if summary.wordCount > 0 {
            steps.append("Transcript word count: \(summary.wordCount)")
        }
        if let notesErrorDescription = summary.notesErrorDescription {
            steps.append("Note generation failed: \(notesErrorDescription)")
        }

        return steps
    }

    func applySavedMeetingSelection() {
        let savedBundleID = defaults.string(forKey: Self.savedMeetingBundleIDKey)
        let savedName = defaults.string(forKey: Self.savedMeetingNameKey)
        let previousID = selectedMeeting?.id

        if let previousID, let existing = detectedMeetings.first(where: { $0.id == previousID }) {
            selectedMeeting = existing
            return
        }

        if let savedBundleID, let match = detectedMeetings.first(where: { $0.bundleID == savedBundleID }) {
            selectedMeeting = match
        } else if let savedName, let match = detectedMeetings.first(where: { $0.appName == savedName }) {
            selectedMeeting = match
        } else {
            selectedMeeting = detectedMeetings.first
        }
    }

    func applySavedMicrophoneSelection(from devices: [AudioInputDevice]) {
        let savedMicID = defaults.string(forKey: Self.savedMicDeviceIDKey)
        let previousMicID = micDevice?.id ?? savedMicID

        micDevice = resolveMicDevice(from: devices, preferredID: previousMicID)
        if let micID = micDevice?.id {
            defaults.set(micID, forKey: Self.savedMicDeviceIDKey)
        }

        if previousMicID != nil, micDevice == nil {
            setupMessage = "Previously selected microphone is unavailable. Choose another input device."
        }
    }

    func resolveMicDevice(from devices: [AudioInputDevice], preferredID: String?) -> AudioInputDevice? {
        if let preferredID, let device = devices.first(where: { $0.id == preferredID }) {
            return device
        }
        return devices.first(where: \.isDefaultInput) ?? devices.first
    }

    func updatePermissionDiagnostics() {
        permissionDiagnostics.microphone = microphonePermissionStatus()
        permissionDiagnostics.selectedMeetingApp = selectedMeeting == nil ? .missing : .granted
        permissionDiagnostics.selectedMicrophone = micDevice == nil ? .missing : .granted
        if phase == .recording || isMonitoringAudio || captureBackendState.streamStarted {
            permissionDiagnostics.appAudioCapture = .granted
        } else if selectedMeeting != nil, micDevice != nil {
            permissionDiagnostics.appAudioCapture = .unknown
        } else {
            permissionDiagnostics.appAudioCapture = .missing
        }
    }

    func microphonePermissionStatus() -> SetupStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .unknown
        case .denied, .restricted:
            return .missing
        @unknown default:
            return .unknown
        }
    }

    func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        open(url: url)
    }

    func regenerateNotes(in directoryURL: URL, transcriptURL: URL?) async {
        guard let transcriptURL else {
            errorMessage = "Transcript file is missing for this meeting."
            return
        }

        let previousPhase = phase
        let previousSteps = processingSteps
        let previousSummary = lastCompletedSummary

        isGeneratingNotes = true
        phase = .processing
        errorMessage = nil
        processingSteps = ["Generating notes..."]

        do {
            let notesURL = try await pipeline.generateNotes(transcriptURL: transcriptURL)
            let notes = try String(contentsOf: notesURL, encoding: .utf8)
            let summaryPreview = notes
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") }

            let existingMetadata = try? await store.loadMetadata(in: directoryURL)
            let transcriptText = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
            let wordCount = existingMetadata?.wordCount ?? transcriptText.split(whereSeparator: \.isWhitespace).count
            let createdAt = existingMetadata?.createdAt ?? inferredCreatedAt(for: directoryURL)
            let metadata = MeetingMetadata(
                createdAt: createdAt,
                duration: existingMetadata?.duration ?? 0,
                wordCount: wordCount,
                targetAppName: existingMetadata?.targetAppName,
                audioCaptureMode: existingMetadata?.audioCaptureMode,
                micDevice: existingMetadata?.micDevice,
                displayName: existingMetadata?.displayName,
                whisperModel: existingMetadata?.whisperModel ?? selectedWhisperModel?.id,
                summaryPreview: summaryPreview ?? existingMetadata?.summaryPreview ?? "Notes generated.",
                recordingFileName: existingMetadata?.recordingFileName,
                audioFileName: existingMetadata?.audioFileName,
                systemAudioFileName: existingMetadata?.systemAudioFileName,
                microphoneAudioFileName: existingMetadata?.microphoneAudioFileName,
                transcriptFileName: existingMetadata?.transcriptFileName ?? transcriptURL.lastPathComponent,
                notesFileName: notesURL.lastPathComponent
            )
            try await store.saveMetadata(metadata, in: directoryURL)

            if previousSummary?.directoryURL == directoryURL {
                lastCompletedSummary = RecordingSessionSummary(
                    directoryURL: directoryURL,
                    recordingURL: previousSummary?.recordingURL,
                    audioURL: previousSummary?.audioURL,
                    systemAudioURL: previousSummary?.systemAudioURL,
                    microphoneAudioURL: previousSummary?.microphoneAudioURL,
                    transcriptURL: transcriptURL,
                    notesURL: notesURL,
                    startedAt: existingMetadata?.createdAt ?? previousSummary?.startedAt ?? createdAt,
                    endedAt: .now,
                    duration: existingMetadata?.duration ?? previousSummary?.duration ?? 0,
                    wordCount: wordCount,
                    targetAppName: existingMetadata?.targetAppName ?? previousSummary?.targetAppName,
                    audioCaptureMode: existingMetadata?.audioCaptureMode?.rawValue ?? previousSummary?.audioCaptureMode,
                    micDevice: existingMetadata?.micDevice ?? previousSummary?.micDevice,
                    whisperModel: metadata.whisperModel,
                    summaryPreview: metadata.summaryPreview,
                    notesErrorDescription: nil
                )
            }

            if let updatedSummary = lastCompletedSummary, previousSummary?.directoryURL == directoryURL {
                processingSteps = completedSteps(for: updatedSummary)
                phase = .complete
            } else {
                processingSteps = previousSteps
                phase = previousPhase
            }
            refreshHistory()
        } catch {
            processingSteps = previousSteps
            phase = previousPhase
            errorMessage = "Note generation failed: \(error.localizedDescription)"
        }

        isGeneratingNotes = false
        refreshAudioMonitoring()
    }

    func inferredCreatedAt(for directoryURL: URL) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        if let date = formatter.date(from: directoryURL.lastPathComponent) {
            return date
        }
        let resourceValues = try? directoryURL.resourceValues(forKeys: [.creationDateKey])
        return resourceValues?.creationDate ?? .now
    }

    func resolveExistingArtifacts(in directory: URL, metadata: MeetingMetadata?) throws -> CaptureSessionArtifacts {
        let fileManager = FileManager.default
        let systemCandidates = [
            metadata?.systemAudioFileName.map { directory.appendingPathComponent($0) },
            directory.appendingPathComponent("system-audio.caf"),
            directory.appendingPathComponent("system_audio.caf")
        ].compactMap { $0 }
        let micCandidates = [
            metadata?.microphoneAudioFileName.map { directory.appendingPathComponent($0) },
            directory.appendingPathComponent("mic-audio.caf"),
            directory.appendingPathComponent("mic_audio.caf"),
            directory.appendingPathComponent("microphone-audio.caf")
        ].compactMap { $0 }

        let systemAudioURL = systemCandidates.first(where: { fileManager.fileExists(atPath: $0.path) })
        let microphoneAudioURL = micCandidates.first(where: { fileManager.fileExists(atPath: $0.path) })

        guard systemAudioURL != nil || microphoneAudioURL != nil else {
            throw NSError(
                domain: "AppModel",
                code: 71,
                userInfo: [NSLocalizedDescriptionKey: "No raw system or microphone CAF files were found in that meeting folder."]
            )
        }

        return CaptureSessionArtifacts(
            mixedAudioURL: nil,
            systemAudioURL: systemAudioURL,
            microphoneAudioURL: microphoneAudioURL
        )
    }

    func duration(of audioURL: URL) throws -> TimeInterval {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(audioFile.length) / sampleRate
    }
}

private struct ProcessedSessionResult {
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let wordCount: Int
    let transcriptURL: URL?
    let notesURL: URL?
    let summaryPreview: String?
    let notesErrorDescription: String?
}
