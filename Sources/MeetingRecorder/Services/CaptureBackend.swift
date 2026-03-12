import Foundation

enum AudioCaptureBackendKind: String, Codable {
    case screenCaptureKit = "ScreenCaptureKit"
    case processTap = "Core Audio Process Tap"
    case importedFile = "Imported File"
}

struct CaptureSessionArtifacts: Codable {
    var mixedAudioURL: URL?
    var systemAudioURL: URL?
    var microphoneAudioURL: URL?
}

struct AudioCaptureBackendState: Codable {
    var backendKind: AudioCaptureBackendKind
    var statusMessage: String
    var failurePoint: String?
    var streamStarted = false
    var didReceiveSystemAudio = false
    var didReceiveMicrophoneAudio = false
    var systemAudioFormat = "Not started"
    var microphoneAudioFormat = "Not started"
    var systemRecentPeak: Float = 0
    var microphoneRecentPeak: Float = 0
    var systemSawNonZeroSamples = false
    var microphoneSawNonZeroSamples = false
    var systemSampleSummary = "No buffers inspected"
    var microphoneSampleSummary = "No buffers inspected"
    var systemWrittenSampleSummary = "No PCM buffers written"
    var microphoneWrittenSampleSummary = "No PCM buffers written"
    var systemAudioURL: URL?
    var microphoneAudioURL: URL?

    static let idle = AudioCaptureBackendState(
        backendKind: .screenCaptureKit,
        statusMessage: "ScreenCaptureKit backend idle"
    )
}

protocol AudioCaptureBackendDelegate: AnyObject {
    func audioCaptureBackend(didUpdateLevels levels: AudioLevels)
    func audioCaptureBackend(didUpdateState state: AudioCaptureBackendState)
}

@MainActor
protocol MeetingAudioCaptureBackend: AnyObject {
    var delegate: AudioCaptureBackendDelegate? { get set }
    var backendKind: AudioCaptureBackendKind { get }

    func startMonitoring(micDeviceID: String) async throws
    func stopMonitoring() async
    func startRecording(micDeviceID: String, in directory: URL) async throws
    func stopRecording() async throws -> CaptureSessionArtifacts
}
