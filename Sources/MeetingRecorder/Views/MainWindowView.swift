import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 460)
        } detail: {
            content
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1040, minHeight: 700)
        .background(
            LinearGradient(
                colors: [RecorderTheme.windowTop, RecorderTheme.windowBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .fileImporter(isPresented: $model.isFileImporterPresented, allowedContentTypes: [.movie, .mpeg4Movie, .audio, .wav, .mp3]) { result in
            model.handleFileImport(result: result)
        }
        .fileImporter(isPresented: $model.isMeetingFolderImporterPresented, allowedContentTypes: [.folder]) { result in
            model.handleMeetingFolderImport(result: result)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop(providers:))
        .overlay(alignment: .bottomTrailing) {
            if isDropTargeted {
                Text("Drop a recording to transcribe")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
        .task {
            await model.initialize()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Meeting Recorder")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(RecorderTheme.primaryText)
                    Text(model.phaseSubtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(RecorderTheme.secondaryText)
                }
                Spacer()
                Button {
                    model.isFileImporterPresented = true
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }

            SectionCard(title: "Status") {
                VStack(spacing: 12) {
                    StatusBadge(title: "Phase", value: model.phase.rawValue.capitalized)
                    StatusBadge(title: "Meeting App", value: model.selectedMeeting?.appName ?? "Select an app")
                }
                VStack(spacing: 12) {
                    StatusBadge(title: "Backend", value: model.captureBackendState.backendKind.rawValue)
                    StatusBadge(title: "Mic", value: model.micDevice?.name ?? "Select a microphone")
                }
            }

            SectionCard(title: "Detected Meetings") {
                if model.detectedMeetings.isEmpty {
                    Text("No active Teams, Zoom, Meet, Slack, Webex, or FaceTime windows were detected.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(RecorderTheme.secondaryText)
                } else {
                    ForEach(model.detectedMeetings) { meeting in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.appName)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(RecorderTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if let title = meeting.windowTitle, !title.isEmpty {
                                Text(title)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(RecorderTheme.secondaryText.opacity(0.9))
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer()

            SectionCard(title: "History Search") {
                TextField("Search transcripts and notes", text: $model.historySearchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.refreshHistory()
                    }
                Button("Refresh History") {
                    model.refreshHistory()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(minWidth: 340, idealWidth: 380, maxWidth: 460, maxHeight: .infinity, alignment: .topLeading)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                recorderCard
                processingCard
                historyCard
            }
            .padding(24)
        }
    }

    private var recorderCard: some View {
        SectionCard(title: "Recorder") {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.phase == .recording ? "Recording in progress" : "Ready to record")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(RecorderTheme.primaryText)
                        Text(model.recordingStatusLine)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(RecorderTheme.secondaryText)
                        Text(model.audioMonitorStatusLine)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(model.isMonitoringAudio ? RecorderTheme.secondaryText : .orange)
                        Text(model.captureBackendState.statusMessage)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(RecorderTheme.secondaryText.opacity(0.92))
                    }
                    Spacer()
                    if model.phase == .recording {
                        Label(model.elapsedRecordingTimeText, systemImage: "record.circle.fill")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.red)
                    } else if model.isMonitoringAudio {
                        Label("Audio Monitor Live", systemImage: "waveform")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                    }
                }

                AudioLevelMeterView(
                    title: "Meeting Audio",
                    subtitle: model.selectedMeeting?.appName ?? "No meeting app selected",
                    level: model.audioLevels.system,
                    tint: Color(red: 1.0, green: 0.45, blue: 0.18),
                    activityText: model.systemAudioActivityText
                )
                AudioLevelMeterView(
                    title: "Microphone",
                    subtitle: model.micDevice?.name ?? "No microphone selected",
                    level: model.audioLevels.mic,
                    tint: Color(red: 0.18, green: 0.72, blue: 0.78),
                    activityText: model.microphoneActivityText
                )

                setupCard

                HStack(spacing: 12) {
                    Button(model.phase == .recording ? "Stop Recording" : "Start Recording") {
                        model.toggleRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartRecording && model.phase != .recording)

                    Button("Open Recording Folder") {
                        model.openMeetingsFolder()
                    }
                    .buttonStyle(.bordered)

                    Button("Process File") {
                        model.isFileImporterPresented = true
                    }
                    .buttonStyle(.bordered)

                    Button("Refresh Audio Check") {
                        model.refreshAudioMonitoring()
                    }
                    .buttonStyle(.bordered)
                }

                if let activeFailureMessage = model.captureFailureBannerMessage {
                    AlertBanner(
                        title: "Recording Failed",
                        message: activeFailureMessage
                    )
                }

                if let setupMessage = model.setupMessage {
                    Text(setupMessage)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(RecorderTheme.secondaryText)
                }

                backendDiagnosticsCard

                if let errorMessage = model.errorMessage, errorMessage != model.captureFailureBannerMessage {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var setupCard: some View {
        SectionCard(title: "Capture Setup") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meeting App")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(RecorderTheme.primaryText)
                    Picker("Meeting App", selection: meetingSelection) {
                        ForEach(model.detectedMeetings) { meeting in
                            let titleSuffix = meeting.windowTitle.map { " - \($0)" } ?? ""
                            let helperSuffix = meeting.audioProcessID != meeting.processID ? " (audio helper)" : ""
                            Text("\(meeting.appName)\(titleSuffix)\(helperSuffix)").tag(meeting.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Microphone")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(RecorderTheme.primaryText)
                    Picker("Microphone", selection: micSelection) {
                        ForEach(model.availableMicDevices) { device in
                            Text("\(device.name) • \(device.transportType)").tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                HStack(spacing: 12) {
                    Button("Test Microphone") {
                        model.runMicrophoneTest()
                    }
                    .buttonStyle(.bordered)

                    Button("Test Meeting Audio") {
                        model.runMeetingAudioTest()
                    }
                    .buttonStyle(.bordered)
                }

                SetupStatusRow(
                    title: "Microphone Access",
                    status: model.permissionDiagnostics.microphone,
                    detail: microphoneDetail,
                    actionTitle: model.permissionDiagnostics.microphone == .granted ? nil : "Open Microphone Settings",
                    action: model.permissionDiagnostics.microphone == .granted ? nil : { model.openMicrophoneSettings() }
                )
                SetupStatusRow(
                    title: "Meeting App",
                    status: model.permissionDiagnostics.selectedMeetingApp,
                    detail: selectedMeetingDetail,
                    actionTitle: nil,
                    action: nil
                )
                SetupStatusRow(
                    title: "Selected Microphone",
                    status: model.permissionDiagnostics.selectedMicrophone,
                    detail: selectedMicrophoneDetail,
                    actionTitle: nil,
                    action: nil
                )
                SetupStatusRow(
                    title: "App Audio Capture",
                    status: model.permissionDiagnostics.appAudioCapture,
                    detail: appAudioDetail,
                    actionTitle: nil,
                    action: nil
                )
            }
        }
    }

    private var processingCard: some View {
        SectionCard(title: "Processing") {
            VStack(alignment: .leading, spacing: 10) {
                if model.phase == .processing || !model.processingSteps.isEmpty {
                    ProcessingProgressView(
                        title: "Pipeline Progress",
                        progress: model.processingProgress,
                        detail: model.processingProgressLabel
                    )
                }
                ForEach(model.processingSteps, id: \.self) { step in
                    Text(step)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(RecorderTheme.primaryText)
                }
                if let summary = model.lastCompletedSummary {
                    Divider().overlay(.white.opacity(0.15))
                    Text("Latest Capture")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(RecorderTheme.primaryText)
                    Text(summary.summaryPreview ?? model.captureOutputSummaryText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(RecorderTheme.secondaryText)
                    if summary.wordCount > 0 {
                        Text("Transcript word count: \(summary.wordCount)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(RecorderTheme.secondaryText)
                    }
                    if summary.transcriptURL != nil {
                        Button(summary.notesURL == nil ? "Generate Notes" : "Re-generate Notes") {
                            model.generateNotesForLastSummary()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isGeneratingNotes)
                    }
                    HStack(spacing: 10) {
                        Button("Open Folder") {
                            model.open(url: summary.directoryURL)
                        }
                        .buttonStyle(.link)
                        if let audioURL = summary.audioURL {
                            Button("Mixed Audio") {
                                model.open(url: audioURL)
                            }
                            .buttonStyle(.link)
                        }
                        if let systemAudioURL = summary.systemAudioURL {
                            Button("System Audio") {
                                model.open(url: systemAudioURL)
                            }
                            .buttonStyle(.link)
                        }
                        if let microphoneAudioURL = summary.microphoneAudioURL {
                            Button("Mic Audio") {
                                model.open(url: microphoneAudioURL)
                            }
                            .buttonStyle(.link)
                        }
                        if let transcriptURL = summary.transcriptURL {
                            Button("Transcript") {
                                model.open(url: transcriptURL)
                            }
                            .buttonStyle(.link)
                        }
                        if let notesURL = summary.notesURL {
                            Button("Notes") {
                                model.open(url: notesURL)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private var historyCard: some View {
        SectionCard(title: "Meeting History") {
            if model.history.isEmpty {
                Text("No recorded meetings yet.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(RecorderTheme.secondaryText)
            } else {
                ForEach(model.history) { meeting in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(meeting.folderName)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(RecorderTheme.primaryText)
                            Spacer()
                            Text(model.formatDuration(meeting.duration))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(RecorderTheme.secondaryText)
                        }
                        Text(meeting.summaryPreview.isEmpty ? "No summary yet." : meeting.summaryPreview)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(RecorderTheme.secondaryText)
                            .lineLimit(2)
                        if meeting.transcriptURL != nil {
                            Button(meeting.notesURL == nil ? "Generate Notes" : "Re-generate Notes") {
                                model.generateNotes(for: meeting)
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isGeneratingNotes)
                        }
                        HStack(spacing: 10) {
                            Button("Open Folder") {
                                model.open(url: meeting.directoryURL)
                            }
                            .buttonStyle(.link)
                            if let audioURL = meeting.audioURL {
                                Button("Mixed Audio") {
                                    model.open(url: audioURL)
                                }
                                .buttonStyle(.link)
                            }
                            if let systemAudioURL = meeting.systemAudioURL {
                                Button("System Audio") {
                                    model.open(url: systemAudioURL)
                                }
                                .buttonStyle(.link)
                            }
                            if let microphoneAudioURL = meeting.microphoneAudioURL {
                                Button("Mic Audio") {
                                    model.open(url: microphoneAudioURL)
                                }
                                .buttonStyle(.link)
                            }
                            if let transcriptURL = meeting.transcriptURL {
                                Button("Transcript") {
                                    model.open(url: transcriptURL)
                                }
                                .buttonStyle(.link)
                            }
                            if let notesURL = meeting.notesURL {
                                Button("Notes") {
                                    model.open(url: notesURL)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard
                let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil)
            else {
                return
            }
            Task { @MainActor in
                model.processImportedFile(url: url)
            }
        }
        return true
    }

    private var meetingSelection: Binding<String> {
        Binding(
            get: { model.selectedMeeting?.id ?? model.detectedMeetings.first?.id ?? "" },
            set: { model.selectMeetingApp(id: $0) }
        )
    }

    private var micSelection: Binding<String> {
        Binding(
            get: { model.micDevice?.id ?? model.availableMicDevices.first?.id ?? "" },
            set: { model.selectMicDevice(id: $0) }
        )
    }

    private var microphoneDetail: String {
        switch model.permissionDiagnostics.microphone {
        case .granted:
            return "Microphone access is available for the current app build."
        case .missing:
            return "Microphone access is disabled for Meeting Recorder."
        case .unknown:
            return "Press Test Microphone and speak once to trigger the permission prompt."
        }
    }

    private var selectedMeetingDetail: String {
        switch model.permissionDiagnostics.selectedMeetingApp {
        case .granted:
            return model.selectedMeeting.map { "Using \($0.appName) as the meeting audio source." } ?? "A meeting app is selected."
        case .missing:
            return "Choose a supported meeting app that is currently running."
        case .unknown:
            return "Meeting app detection has not resolved yet."
        }
    }

    private var selectedMicrophoneDetail: String {
        switch model.permissionDiagnostics.selectedMicrophone {
        case .granted:
            return model.micDevice.map { "Using \($0.name) for native microphone capture." } ?? "A microphone is selected."
        case .missing:
            return "Choose a microphone to enable native microphone capture."
        case .unknown:
            return "Microphone selection has not been resolved yet."
        }
    }

    private var appAudioDetail: String {
        switch model.permissionDiagnostics.appAudioCapture {
        case .granted:
            return "The ScreenCaptureKit audio monitor or recorder is currently active."
        case .missing:
            return "Audio capture cannot start until a meeting app and microphone are selected."
        case .unknown:
            return "Audio capture is ready but idle. Press Refresh Audio Check or Test Meeting Audio."
        }
    }

    private var backendDiagnosticsCard: some View {
        SectionCard(title: "Backend Diagnostics") {
            VStack(alignment: .leading, spacing: 8) {
                diagnosticRow(label: "Backend", value: model.captureBackendState.backendKind.rawValue)
                diagnosticRow(label: "Status", value: model.captureBackendState.statusMessage)
                diagnosticRow(label: "Failure Point", value: model.captureBackendState.failurePoint ?? "None")
                diagnosticRow(label: "Stream Started", value: model.captureBackendState.streamStarted ? "Yes" : "No")
                diagnosticRow(label: "First System Frame", value: model.captureBackendState.didReceiveSystemAudio ? "Yes" : "No")
                diagnosticRow(label: "First Mic Frame", value: model.captureBackendState.didReceiveMicrophoneAudio ? "Yes" : "No")
                diagnosticRow(label: "System Format", value: model.captureBackendState.systemAudioFormat)
                diagnosticRow(label: "Mic Format", value: model.captureBackendState.microphoneAudioFormat)
                diagnosticRow(label: "System Peak", value: String(format: "%.6f", model.captureBackendState.systemRecentPeak))
                diagnosticRow(label: "Mic Peak", value: String(format: "%.6f", model.captureBackendState.microphoneRecentPeak))
                diagnosticRow(label: "System Non-Zero", value: model.captureBackendState.systemSawNonZeroSamples ? "Yes" : "No")
                diagnosticRow(label: "Mic Non-Zero", value: model.captureBackendState.microphoneSawNonZeroSamples ? "Yes" : "No")
                diagnosticRow(label: "System Sample", value: model.captureBackendState.systemSampleSummary)
                diagnosticRow(label: "Mic Sample", value: model.captureBackendState.microphoneSampleSummary)
                diagnosticRow(label: "System PCM", value: model.captureBackendState.systemWrittenSampleSummary)
                diagnosticRow(label: "Mic PCM", value: model.captureBackendState.microphoneWrittenSampleSummary)
                if let systemAudioURL = model.captureBackendState.systemAudioURL {
                    diagnosticRow(label: "System File", value: systemAudioURL.lastPathComponent)
                }
                if let microphoneAudioURL = model.captureBackendState.microphoneAudioURL {
                    diagnosticRow(label: "Mic File", value: microphoneAudioURL.lastPathComponent)
                }
            }
        }
    }

    private func diagnosticRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(RecorderTheme.secondaryText)
                .frame(width: 132, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(RecorderTheme.primaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
