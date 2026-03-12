import AppKit
import Foundation

enum AppPhase: String, Codable {
    case idle
    case recording
    case processing
    case complete
    case failed
}

struct AudioInputDevice: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let transportType: String
    let isDefaultInput: Bool
}

struct MeetingAppPresence: Identifiable, Hashable, Codable {
    let id: String
    let appName: String
    let bundleID: String?
    let processID: Int32
    let audioProcessID: Int32
    let windowTitle: String?
}

struct AudioLevels: Codable {
    var system: Float = 0
    var mic: Float = 0
}

enum SetupStatus: String, Codable {
    case granted
    case missing
    case unknown

    var label: String {
        switch self {
        case .granted:
            return "Granted"
        case .missing:
            return "Missing"
        case .unknown:
            return "Unknown"
        }
    }
}

struct PermissionDiagnostics: Codable {
    var microphone: SetupStatus = .unknown
    var selectedMeetingApp: SetupStatus = .unknown
    var selectedMicrophone: SetupStatus = .unknown
    var appAudioCapture: SetupStatus = .unknown
}

struct RecordingSessionSummary: Codable {
    let directoryURL: URL
    let recordingURL: URL?
    let audioURL: URL?
    let systemAudioURL: URL?
    let microphoneAudioURL: URL?
    let transcriptURL: URL?
    let notesURL: URL?
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let wordCount: Int
    let targetAppName: String?
    let audioCaptureMode: String?
    let micDevice: String?
    let whisperModel: String?
    let summaryPreview: String?
    let notesErrorDescription: String?
}

struct MeetingRecord: Identifiable, Codable, Hashable {
    let id: String
    let folderName: String
    let directoryURL: URL
    let recordingURL: URL?
    let audioURL: URL?
    let systemAudioURL: URL?
    let microphoneAudioURL: URL?
    let transcriptURL: URL?
    let notesURL: URL?
    let createdAt: Date
    let duration: TimeInterval
    let wordCount: Int
    let summaryPreview: String
    let targetAppName: String?
}

struct WhisperModelInfo: Identifiable, Hashable {
    let id: String
    let sizeName: String
    let fileURL: URL
    let fileSizeDescription: String
}

struct MeetingMetadata: Codable {
    let createdAt: Date
    let duration: TimeInterval
    let wordCount: Int
    let targetAppName: String?
    let audioCaptureMode: AudioCaptureBackendKind?
    let micDevice: String?
    let displayName: String?
    let whisperModel: String?
    let summaryPreview: String?
    let recordingFileName: String?
    let audioFileName: String?
    let systemAudioFileName: String?
    let microphoneAudioFileName: String?
    let transcriptFileName: String?
    let notesFileName: String?
}
