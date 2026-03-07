import Foundation
import AVFoundation

@MainActor
final class AudioLevelMonitor: NSObject, ObservableObject {
    @Published private(set) var systemLevel: Double = 0
    @Published private(set) var micLevel: Double = 0

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "meeting-recorder.audio-meter")
    private var deviceRoleByUniqueID: [String: DeviceRole] = [:]
    private var decayTimer: Timer?

    enum DeviceRole {
        case system
        case mic
    }

    func start(systemDeviceID: String, micDeviceID: String) throws {
        stop()

        try configureSession(systemDeviceID: systemDeviceID, micDeviceID: micDeviceID)
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.startRunning()
        startDecayTimer()
    }

    func stop() {
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        session.commitConfiguration()

        deviceRoleByUniqueID.removeAll()
        stopDecayTimer()
        systemLevel = 0
        micLevel = 0
    }

    private func configureSession(systemDeviceID: String, micDeviceID: String) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let systemDevice = AVCaptureDevice(uniqueID: systemDeviceID) {
            let input = try AVCaptureDeviceInput(device: systemDevice)
            if session.canAddInput(input) {
                session.addInput(input)
                deviceRoleByUniqueID[systemDevice.uniqueID] = .system
            }
        }

        if micDeviceID != systemDeviceID, let micDevice = AVCaptureDevice(uniqueID: micDeviceID) {
            let input = try AVCaptureDeviceInput(device: micDevice)
            if session.canAddInput(input) {
                session.addInput(input)
                deviceRoleByUniqueID[micDevice.uniqueID] = .mic
            }
        }

        if micDeviceID == systemDeviceID {
            deviceRoleByUniqueID[micDeviceID] = .mic
        }
    }

    private func startDecayTimer() {
        decayTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.systemLevel = max(0, self.systemLevel - 0.04)
            self.micLevel = max(0, self.micLevel - 0.04)
        }
    }

    private func stopDecayTimer() {
        decayTimer?.invalidate()
        decayTimer = nil
    }

    private func updateLevel(_ level: Double, role: DeviceRole) {
        switch role {
        case .system:
            systemLevel = max(systemLevel * 0.78, level)
        case .mic:
            micLevel = max(micLevel * 0.78, level)
        }
    }

    nonisolated private static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return 0
        }

        let asbd = asbdPtr.pointee
        let bytesLength = CMBlockBufferGetDataLength(blockBuffer)
        guard bytesLength > 0 else { return 0 }

        var data = Data(count: bytesLength)
        data.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            _ = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: bytesLength, destination: baseAddress)
        }

        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        if isFloat && bitsPerChannel == 32 {
            return data.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Float.self)
                guard !values.isEmpty else { return 0 }
                let sumSquares = values.reduce(Float(0)) { $0 + ($1 * $1) }
                let rms = sqrt(sumSquares / Float(values.count))
                return Double(min(max(rms, 0), 1))
            }
        }

        return data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            guard !values.isEmpty else { return 0 }
            let sumSquares = values.reduce(Double(0)) {
                let sample = Double($1) / Double(Int16.max)
                return $0 + (sample * sample)
            }
            let rms = sqrt(sumSquares / Double(values.count))
            return min(max(rms, 0), 1)
        }
    }
}

extension AudioLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let input = connection.inputPorts.first?.input as? AVCaptureDeviceInput else { return }
        let uniqueID = input.device.uniqueID
        let level = Self.normalizedLevel(from: sampleBuffer)

        Task { @MainActor [weak self] in
            guard let self, let role = self.deviceRoleByUniqueID[uniqueID] else { return }
            self.updateLevel(level, role: role)
        }
    }
}
