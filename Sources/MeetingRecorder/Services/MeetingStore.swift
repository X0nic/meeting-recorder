import Foundation

actor MeetingStore {
    static let shared = MeetingStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    let meetingsDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.meetingsDirectory = baseDirectory
        } else {
            let documents = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
            self.meetingsDirectory = documents.appendingPathComponent("meetings", isDirectory: true)
        }
    }

    func ensureBaseDirectory() throws {
        try fileManager.createDirectory(at: meetingsDirectory, withIntermediateDirectories: true)
    }

    func createSessionDirectory(date: Date = .now) throws -> URL {
        try ensureBaseDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = formatter.string(from: date)
        let url = meetingsDirectory.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func saveMetadata(_ metadata: MeetingMetadata, in directory: URL) throws {
        let url = directory.appendingPathComponent("meeting.meta")
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    func loadMetadata(in directory: URL) throws -> MeetingMetadata {
        let url = directory.appendingPathComponent("meeting.meta")
        let data = try Data(contentsOf: url)
        return try decoder.decode(MeetingMetadata.self, from: data)
    }

    func loadHistory(searchTerm: String = "") -> [MeetingRecord] {
        (try? ensureBaseDirectory()) ?? ()
        let folderURLs = (try? fileManager.contentsOfDirectory(
            at: meetingsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return folderURLs.compactMap { folderURL in
            let metadataURL = folderURL.appendingPathComponent("meeting.meta")
            let meetingRecord: MeetingRecord

            if
                let data = try? Data(contentsOf: metadataURL),
                let metadata = try? decoder.decode(MeetingMetadata.self, from: data),
                let hydratedRecord = record(from: metadata, in: folderURL)
            {
                meetingRecord = hydratedRecord
            } else if let inferredRecord = inferRecord(in: folderURL) {
                meetingRecord = inferredRecord
            } else {
                return nil
            }

            if !searchTerm.isEmpty {
                let query = searchTerm.localizedLowercase
                let transcript = meetingRecord.transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let notes = meetingRecord.notesURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                let haystack = [meetingRecord.summaryPreview, transcript, notes].joined(separator: "\n").localizedLowercase
                guard haystack.contains(query) else { return nil }
            }

            return meetingRecord
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func record(from metadata: MeetingMetadata, in folderURL: URL) -> MeetingRecord? {
        MeetingRecord(
            id: folderURL.lastPathComponent,
            folderName: folderURL.lastPathComponent,
            directoryURL: folderURL,
            recordingURL: resolvedFileURL(from: metadata.recordingFileName, in: folderURL),
            audioURL: resolvedFileURL(from: metadata.audioFileName, in: folderURL),
            systemAudioURL: resolvedFileURL(from: metadata.systemAudioFileName, in: folderURL),
            microphoneAudioURL: resolvedFileURL(from: metadata.microphoneAudioFileName, in: folderURL),
            transcriptURL: resolvedFileURL(from: metadata.transcriptFileName, in: folderURL),
            notesURL: resolvedFileURL(from: metadata.notesFileName, in: folderURL),
            createdAt: metadata.createdAt,
            duration: metadata.duration,
            wordCount: metadata.wordCount,
            summaryPreview: metadata.summaryPreview ?? "",
            targetAppName: metadata.targetAppName ?? metadata.displayName
        )
    }

    private func resolvedFileURL(from fileName: String?, in folderURL: URL) -> URL? {
        guard let fileName else { return nil }
        let url = folderURL.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func inferRecord(in folderURL: URL) -> MeetingRecord? {
        let transcriptURL = firstExistingFile(
            named: ["transcript.txt", "audio.txt"],
            in: folderURL
        )
        let notesURL = firstExistingFile(named: ["notes.md"], in: folderURL)
        let audioURL = firstExistingFile(named: ["audio.wav", "audio.m4a", "audio.mp3", "audio.caf"], in: folderURL)
        let systemAudioURL = firstExistingFile(named: ["system_audio.caf", "system-audio.caf"], in: folderURL)
        let microphoneAudioURL = firstExistingFile(named: ["microphone_audio.caf", "mic_audio.caf", "microphone-audio.caf"], in: folderURL)
        let recordingURL = firstExistingFile(named: ["recording.mov", "recording.mp4"], in: folderURL)

        guard transcriptURL != nil || notesURL != nil || audioURL != nil || recordingURL != nil else {
            return nil
        }

        let resourceValues = try? folderURL.resourceValues(forKeys: [.creationDateKey])
        let createdAt = resourceValues?.creationDate ?? inferredDate(from: folderURL.lastPathComponent) ?? .distantPast
        let transcriptText = transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let notesText = notesURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let summaryPreview = inferredSummary(notes: notesText, transcript: transcriptText)

        return MeetingRecord(
            id: folderURL.lastPathComponent,
            folderName: folderURL.lastPathComponent,
            directoryURL: folderURL,
            recordingURL: recordingURL,
            audioURL: audioURL,
            systemAudioURL: systemAudioURL,
            microphoneAudioURL: microphoneAudioURL,
            transcriptURL: transcriptURL,
            notesURL: notesURL,
            createdAt: createdAt,
            duration: 0,
            wordCount: transcriptText.split(whereSeparator: \.isWhitespace).count,
            summaryPreview: summaryPreview,
            targetAppName: nil
        )
    }

    private func firstExistingFile(named fileNames: [String], in folderURL: URL) -> URL? {
        for fileName in fileNames {
            let url = folderURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func inferredDate(from folderName: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: folderName)
    }

    private func inferredSummary(notes: String, transcript: String) -> String {
        let noteSummary = notes
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }

        if let noteSummary {
            return noteSummary
        }
        if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Transcript available. Notes have not been generated yet."
        }
        return "Recovered meeting artifacts."
    }
}
