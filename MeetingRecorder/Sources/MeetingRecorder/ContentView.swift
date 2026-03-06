import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()

            switch model.phase {
            case .idle:
                idleSection
            case .recording:
                recordingSection
            case .processing:
                processingSection
            case .complete:
                completeSection
            case .failed(let message):
                failedSection(message)
            }

            Divider()
            historySection
        }
        .padding(14)
        .frame(minWidth: 430, idealWidth: 460, maxWidth: 560, minHeight: 520)
        .background(dropTargeted ? Color.orange.opacity(0.15) : Color.clear)
        .onAppear { model.onAppear() }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted, perform: onDrop(providers:))
        .fileImporter(
            isPresented: $model.shouldPresentFileImporter,
            allowedContentTypes: [.movie, .mpeg4Movie, .audio, UTType(filenameExtension: "wav") ?? .audio]
        ) { result in
            guard case .success(let url) = result else { return }
            model.processExternalFile(url)
        }
    }

    private var header: some View {
        HStack {
            Text("Meeting Recorder")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                Task { await model.refreshDevicesAndApps() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            Button {
                model.presentFileImporter()
            } label: {
                Label("Open", systemImage: "folder")
            }
        }
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready")
                .font(.headline)

            Picker("Screen", selection: Binding(
                get: { model.selectedScreenID ?? 0 },
                set: { model.selectedScreenID = $0 }
            )) {
                ForEach(model.deviceService.screenOptions) { screen in
                    Text(screen.name).tag(screen.displayID)
                }
            }

            Picker("System Audio", selection: Binding(
                get: { model.selectedSystemAudioID ?? "" },
                set: { model.selectedSystemAudioID = $0 }
            )) {
                ForEach(model.deviceService.audioDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }

            Picker("Microphone", selection: Binding(
                get: { model.selectedMicID ?? "" },
                set: { model.selectedMicID = $0 }
            )) {
                ForEach(model.deviceService.audioDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }

            if !model.detector.matches.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detected Meeting Apps")
                        .font(.subheadline.weight(.semibold))
                    ForEach(model.detector.matches) { match in
                        Text("• \(match.appName) on \(match.screenName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button(action: model.startRecording) {
                Text("Start Recording")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("● Recording")
                    .foregroundStyle(.red)
                    .font(.headline)
                Spacer()
                Text(model.elapsedText)
                    .monospacedDigit()
            }

            MeterRow(title: "System Audio", level: model.meter.systemLevel)
            MeterRow(title: "Microphone", level: model.meter.micLevel)

            Button(role: .destructive, action: model.stopRecording) {
                Text("Stop Recording")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var processingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Processing")
                .font(.headline)
            ForEach(model.processingSteps) { step in
                HStack {
                    Image(systemName: icon(for: step.status))
                        .foregroundStyle(color(for: step.status))
                    Text(step.label)
                }
                .font(.subheadline)
            }
        }
    }

    private var completeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Complete")
                .font(.headline)
            Text("Transcript words: \(model.transcriptWordCount)")
                .font(.subheadline)

            HStack {
                if let notes = model.latestResult?.notesURL {
                    Button("Open Notes") { model.openURL(notes) }
                }
                if let transcript = model.latestResult?.transcriptURL {
                    Button("Open Transcript") { model.openURL(transcript) }
                }
                if let folder = model.latestResult?.meetingFolder {
                    Button("Open Folder") { model.openURL(folder) }
                }
            }

            Button("New Recording") {
                model.newRecording()
            }
        }
    }

    private func failedSection(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Failed")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset") {
                model.newRecording()
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting History")
                .font(.headline)

            TextField("Search transcripts and notes", text: $model.historySearch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.historySearch) { _, _ in
                    model.refreshHistory()
                }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.history.meetings) { meeting in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(meeting.id)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(meeting.durationText)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if !meeting.summary.isEmpty {
                                Text(meeting.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack {
                                Button("Notes") { model.openURL(meeting.notesURL) }
                                Button("Transcript") { model.openURL(meeting.transcriptURL) }
                                if let recording = meeting.recordingURL {
                                    Button("Recording") { model.openURL(recording) }
                                }
                            }
                            .font(.caption)
                        }
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func icon(for status: ProcessingStep.StepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "clock"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for status: ProcessingStep.StepStatus) -> Color {
        switch status {
        case .pending: return .secondary
        case .running: return .orange
        case .success: return .green
        case .failed: return .red
        }
    }

    private func onDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let nsURL = item as? NSURL {
                url = nsURL as URL
            } else {
                url = nil
            }
            guard let url else { return }
            DispatchQueue.main.async {
                model.processExternalFile(url)
            }
        }
        return true
    }
}

private struct MeterRow: View {
    let title: String
    let level: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .frame(width: 100, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(levelColor)
                        .frame(width: max(3, proxy.size.width * min(level, 1)))
                }
            }
            .frame(height: 12)
            Text(String(format: "%.2f", level))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private var levelColor: Color {
        if level > 0.7 {
            return .red
        }
        if level > 0.35 {
            return .orange
        }
        return .green
    }
}
