import Foundation

@MainActor
final class MeetingHistoryStore: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []

    func refresh(root: URL, search: String = "") {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            meetings = []
            return
        }

        let loaded = folders.compactMap { folder -> MeetingRecord? in
            let notesURL = folder.appendingPathComponent("notes.md")
            let transcriptURL = folder.appendingPathComponent("transcript.txt")
            guard fm.fileExists(atPath: notesURL.path) || fm.fileExists(atPath: transcriptURL.path) else {
                return nil
            }

            let transcript = (try? String(contentsOf: transcriptURL)) ?? ""
            let notes = (try? String(contentsOf: notesURL)) ?? ""
            let summary = notesSummary(notes)
            let duration = durationText(folder: folder)

            let name = folder.lastPathComponent
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm"
            let date = formatter.date(from: name) ?? Date.distantPast

            return MeetingRecord(
                id: name,
                folderURL: folder,
                createdAt: date,
                durationText: duration,
                summary: summary,
                transcript: transcript,
                notesURL: notesURL,
                transcriptURL: transcriptURL,
                recordingURL: recordingURL(in: folder)
            )
        }
        .sorted { $0.createdAt > $1.createdAt }

        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            meetings = loaded
            return
        }

        let query = search.lowercased()
        meetings = loaded.filter {
            $0.summary.lowercased().contains(query)
                || $0.transcript.lowercased().contains(query)
                || ((try? String(contentsOf: $0.notesURL).lowercased().contains(query)) ?? false)
        }
    }

    private func durationText(folder: URL) -> String {
        let metaURL = folder.appendingPathComponent("meeting.meta")
        guard let content = try? String(contentsOf: metaURL),
              let line = content.split(separator: "\n").first(where: { $0.hasPrefix("duration=") }),
              let seconds = Int(line.replacing("duration=", with: "")) else {
            return "N/A"
        }

        let hours = seconds / 3600
        let mins = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, mins, secs)
    }

    private func notesSummary(_ notes: String) -> String {
        let lines = notes.split(separator: "\n").map(String.init)
        guard let summaryLine = lines.firstIndex(of: "## Summary") else {
            return ""
        }
        for line in lines.dropFirst(summaryLine + 1) {
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return line
            }
        }
        return ""
    }

    private func recordingURL(in folder: URL) -> URL? {
        let fm = FileManager.default
        for ext in ["mov", "mp4", "m4v", "wav"] {
            let file = folder.appendingPathComponent("recording.\(ext)")
            if fm.fileExists(atPath: file.path) {
                return file
            }
        }
        let fallback = folder.appendingPathComponent("recording.mov")
        return fm.fileExists(atPath: fallback.path) ? fallback : nil
    }
}

private extension String {
    func replacing(_ target: String, with replacement: String) -> String {
        replacingOccurrences(of: target, with: replacement)
    }
}
