import Foundation

enum PermissionState: String {
    case granted = "Granted"
    case denied = "Denied"
    case notDetermined = "Not Determined"
    case unavailable = "Unavailable"
}

struct PermissionSnapshot {
    var screenRecording: PermissionState = .notDetermined
    var microphone: PermissionState = .notDetermined
}

struct ProbeStatusEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String

    var timestampText: String {
        ProbeStatusEvent.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct ProbeOutputPaths {
    let folderURL: URL
    let systemAudioURL: URL
    let microphoneAudioURL: URL
}

enum BackendVerdict: String {
    case pending = "Pending"
    case viable = "Viable"
    case nonViable = "Non-viable"
}

enum ProbeRunState: String {
    case idle = "Idle"
    case starting = "Starting"
    case running = "Running"
    case stopping = "Stopping"
    case failed = "Failed"
}

struct AudioDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
}
