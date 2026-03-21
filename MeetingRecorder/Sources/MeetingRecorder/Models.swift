import Foundation
import CoreGraphics

enum RecorderPhase: Equatable {
    case idle
    case recording
    case processing
    case complete
    case failed(String)
}

struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isBlackHole: Bool
    let isMicrophone: Bool
    let avFoundationIndex: Int?
}

struct ScreenOption: Identifiable, Hashable {
    var id: CGDirectDisplayID { displayID }
    let displayID: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let ffmpegIndex: Int?
}

struct RecordingConfiguration {
    let screen: ScreenOption
    let systemAudio: AudioDevice
    let microphone: AudioDevice
}

struct MeetingAppMatch: Identifiable, Hashable {
    let id = UUID()
    let appName: String
    let screenName: String
}

struct ProcessingStep: Identifiable, Hashable {
    let id = UUID()
    let label: String
    var status: StepStatus

    enum StepStatus: String {
        case pending
        case running
        case success
        case failed
    }
}

struct MeetingRecord: Identifiable, Hashable {
    let id: String
    let folderURL: URL
    let createdAt: Date
    let durationText: String
    let summary: String
    let transcript: String
    let notesURL: URL
    let transcriptURL: URL
    let recordingURL: URL?
}

struct ProcessingResult {
    let meetingFolder: URL
    let transcriptURL: URL
    let notesURL: URL
    let wordCount: Int
}
