@preconcurrency import AVFoundation
import CoreAudio
import Foundation

protocol AudioCaptureServiceDelegate: AnyObject {
    func audioCaptureService(_ service: AudioCaptureService, didUpdateLevels levels: AudioLevels)
    func audioCaptureService(_ service: AudioCaptureService, didUpdateStatus status: String?)
}

final class AudioCaptureService: NSObject, @unchecked Sendable {
    weak var delegate: AudioCaptureServiceDelegate?

    private let appCapture = ProcessTapCapture()
    private let micCapture = SingleAudioCapture(kind: .mic)
    private var currentLevels = AudioLevels()
    private var activeAudioURL: URL?
    private var isMonitoring = false
    private var currentStatus: String?

    override init() {
        super.init()
        appCapture.levelHandler = { [weak self] level in
            guard let self else { return }
            currentLevels.system = level
            delegate?.audioCaptureService(self, didUpdateLevels: currentLevels)
        }
        appCapture.statusHandler = { [weak self] status in
            guard let self else { return }
            currentStatus = status
            delegate?.audioCaptureService(self, didUpdateStatus: status)
        }
        micCapture.levelHandler = { [weak self] level in
            guard let self else { return }
            currentLevels.mic = level
            delegate?.audioCaptureService(self, didUpdateLevels: currentLevels)
        }
    }

    func startRecording(processID: Int32, micDeviceID: String, in directory: URL) throws -> URL {
        stopMonitoring()
        let audioURL = directory.appendingPathComponent("audio.wav")
        let appAudioURL = directory.appendingPathComponent("meeting-app.caf")
        let micURL = directory.appendingPathComponent("mic-input.caf")

        currentStatus = "Starting app audio capture for PID \(processID)"
        delegate?.audioCaptureService(self, didUpdateStatus: currentStatus)
        try appCapture.start(processID: processID, fileURL: appAudioURL)
        try micCapture.start(deviceID: micDeviceID, fileURL: micURL)
        activeAudioURL = audioURL
        return audioURL
    }

    func stopRecording() async throws -> URL {
        async let appSource = appCapture.stop()
        async let micSource = micCapture.stop()
        let sourceURLs = try await [appSource, micSource]

        guard let activeAudioURL else {
            throw NSError(domain: "AudioCaptureService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active recording output URL."])
        }

        try AudioMixer.mix(sourceURLs: sourceURLs, outputURL: activeAudioURL)
        return activeAudioURL
    }

    func startMonitoring(processID: Int32, micDeviceID: String) throws {
        if isMonitoring,
           appCapture.currentProcessID == processID,
           micCapture.currentDeviceID == micDeviceID {
            return
        }

        stopMonitoring()
        currentStatus = "Starting app audio monitor for PID \(processID)"
        delegate?.audioCaptureService(self, didUpdateStatus: currentStatus)
        try appCapture.startMonitoring(processID: processID)
        try micCapture.startMonitoring(deviceID: micDeviceID)
        isMonitoring = true
    }

    func stopMonitoring() {
        appCapture.stopMonitoring()
        micCapture.stopMonitoring()
        isMonitoring = false
        currentLevels = AudioLevels()
        currentStatus = nil
        delegate?.audioCaptureService(self, didUpdateLevels: currentLevels)
        delegate?.audioCaptureService(self, didUpdateStatus: nil)
    }
}

enum MicrophoneDeviceCatalog {
    static func availableMicrophones() -> [AudioInputDevice] {
        let defaultInputID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .microphone], mediaType: .audio, position: .unspecified).devices
            .map { device in
                AudioInputDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    transportType: transportLabel(for: device),
                    isDefaultInput: device.uniqueID == defaultInputID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefaultInput != rhs.isDefaultInput {
                    return lhs.isDefaultInput
                }
                return lhs.name < rhs.name
            }
    }

    private static func transportLabel(for device: AVCaptureDevice) -> String {
        let name = device.localizedName.localizedLowercase
        if name.contains("airpods") || name.contains("bluetooth") {
            return "Bluetooth"
        }
        if name.contains("usb") {
            return "USB"
        }
        return "Built-in"
    }
}

private enum AudioCaptureKind {
    case mic
}

private final class SingleAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    var levelHandler: ((Float) -> Void)?
    private(set) var currentDeviceID: String?

    private let kind: AudioCaptureKind
    private let session = AVCaptureSession()
    private let dataOutput = AVCaptureAudioDataOutput()
    private let fileOutput = AVCaptureAudioFileOutput()
    private let queue: DispatchQueue

    private var currentURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?

    init(kind: AudioCaptureKind) {
        self.kind = kind
        self.queue = DispatchQueue(label: "meeting.audio.\(kind)")
        super.init()
    }

    func start(deviceID: String, fileURL: URL) throws {
        try configureSession(deviceID: deviceID, includeFileOutput: true)
        currentURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        session.startRunning()
        fileOutput.startRecording(to: fileURL, outputFileType: .caf, recordingDelegate: self)
    }

    func startMonitoring(deviceID: String) throws {
        try configureSession(deviceID: deviceID, includeFileOutput: false)
        currentURL = nil
        session.startRunning()
    }

    func stop() async throws -> URL {
        guard let currentURL else {
            throw NSError(domain: "SingleAudioCapture", code: 13, userInfo: [NSLocalizedDescriptionKey: "Microphone capture was not started."])
        }

        if fileOutput.isRecording {
            return try await withCheckedThrowingContinuation { continuation in
                stopContinuation = continuation
                fileOutput.stopRecording()
            }
        }

        session.stopRunning()
        return currentURL
    }

    func stopMonitoring() {
        if fileOutput.isRecording {
            fileOutput.stopRecording()
        }
        if session.isRunning {
            session.stopRunning()
        }
        currentURL = nil
        currentDeviceID = nil
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        session.stopRunning()
        defer {
            currentURL = nil
        }
        if let error {
            stopContinuation?.resume(throwing: error)
        } else {
            stopContinuation?.resume(returning: outputFileURL)
        }
        stopContinuation = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let level = sampleBuffer.averagePowerLevel else { return }
        DispatchQueue.main.async { [weak self] in
            self?.levelHandler?(level)
        }
    }

    private func configureSession(deviceID: String, includeFileOutput: Bool) throws {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .microphone], mediaType: .audio, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) else {
            throw NSError(domain: "SingleAudioCapture", code: 10, userInfo: [NSLocalizedDescriptionKey: "Audio device not found: \(deviceID)"])
        }

        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "SingleAudioCapture", code: 11, userInfo: [NSLocalizedDescriptionKey: "Unable to attach microphone \(device.localizedName)."])
        }
        session.addInput(input)

        dataOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(dataOutput) else {
            throw NSError(domain: "SingleAudioCapture", code: 12, userInfo: [NSLocalizedDescriptionKey: "Unable to attach audio data output for \(device.localizedName)."])
        }
        session.addOutput(dataOutput)

        if includeFileOutput {
            guard session.canAddOutput(fileOutput) else {
                throw NSError(domain: "SingleAudioCapture", code: 13, userInfo: [NSLocalizedDescriptionKey: "Unable to attach microphone file output for \(device.localizedName)."])
            }
            session.addOutput(fileOutput)
        }

        session.commitConfiguration()
        currentDeviceID = deviceID
    }
}

private final class ProcessTapCapture: @unchecked Sendable {
    var levelHandler: ((Float) -> Void)?
    var statusHandler: ((String?) -> Void)?
    private(set) var currentProcessID: Int32?

    private let writerQueue = DispatchQueue(label: "meeting.process-tap.writer")

    private var tapID: AudioObjectID = .zero
    private var aggregateDeviceID: AudioObjectID = .zero
    private var ioProcID: AudioDeviceIOProcID?
    private var currentURL: URL?
    private var fileFormat: AVAudioFormat?
    private var outputFile: AVAudioFile?
    private var receivedAnyFrames = false

    func start(processID: Int32, fileURL: URL) throws {
        try configure(processID: processID, fileURL: fileURL)
    }

    func startMonitoring(processID: Int32) throws {
        try configure(processID: processID, fileURL: nil)
    }

    func stop() async throws -> URL {
        guard let currentURL else {
            throw NSError(domain: "ProcessTapCapture", code: 70, userInfo: [NSLocalizedDescriptionKey: "Meeting audio capture was not started."])
        }
        try await stopCapture()
        return currentURL
    }

    func stopMonitoring() {
        Task {
            try? await stopCapture()
        }
    }

    private func configure(processID: Int32, fileURL: URL?) throws {
        destroyCurrentCapture()

        let processObjectID = try translateProcessID(processID)
        guard processObjectID != kAudioObjectUnknown else {
            throw NSError(domain: "ProcessTapCapture", code: 71, userInfo: [NSLocalizedDescriptionKey: "No active Core Audio process object was found for PID \(processID). Start audio playback in the meeting app and try again."])
        }
        statusHandler?("Resolved app audio process object \(processObjectID) for PID \(processID)")

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.name = "Meeting Recorder Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = .zero
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), operation: "create process tap")
        statusHandler?("Created process tap \(tapID) for PID \(processID)")

        let tapUID = try tapUID(for: tapID)
        let aggregateDescription = try buildAggregateDeviceDescription(tapUID: tapUID)

        var aggregateDeviceID: AudioObjectID = .zero
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID), operation: "create aggregate device")
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
        statusHandler?("Created aggregate audio device \(aggregateDeviceID)")

        let format = try tapFormat(for: tapID)
        let writerFile: AVAudioFile?
        if let fileURL {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            writerFile = try AVAudioFile(forWriting: fileURL, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } else {
            writerFile = nil
        }

        receivedAnyFrames = false
        var ioProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, writerQueue) { [weak self] _, inputData, _, _, _ in
                guard let self else { return }
                let frames = Self.frameLength(for: inputData)
                let level = Self.averagePowerLevel(for: inputData)
                if frames > 0, !self.receivedAnyFrames {
                    self.receivedAnyFrames = true
                    DispatchQueue.main.async {
                        self.statusHandler?("Receiving app audio frames from PID \(processID)")
                    }
                }
                DispatchQueue.main.async {
                    self.levelHandler?(level)
                }
                guard frames > 0, writerFile != nil, let format = self.fileFormat else { return }
                let chunk = CapturedAudioChunk.copying(inputData, frameLength: frames)
                self.write(chunk: chunk, format: format)
            },
            operation: "create aggregate device IO block"
        )

        do {
            try check(AudioDeviceStart(aggregateDeviceID, ioProcID), operation: "start aggregate device")
        } catch {
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
        statusHandler?("Started aggregate audio device for PID \(processID)")

        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.ioProcID = ioProcID
        self.currentProcessID = processID
        self.currentURL = fileURL
        self.fileFormat = format
        self.outputFile = writerFile
    }

    private func stopCapture() async throws {
        if let ioProcID, aggregateDeviceID != .zero {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                self?.outputFile = nil
                continuation.resume()
            }
        }

        destroyCurrentCapture()
    }

    private func destroyCurrentCapture() {
        if let ioProcID, aggregateDeviceID != .zero {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if aggregateDeviceID != .zero {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if tapID != .zero {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateDeviceID = .zero
        tapID = .zero
        currentProcessID = nil
        currentURL = nil
        fileFormat = nil
        outputFile = nil
        receivedAnyFrames = false
        statusHandler?(nil)
    }

    private func write(chunk: CapturedAudioChunk, format: AVAudioFormat) {
        guard let outputFile else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.frameLength) else { return }
        buffer.frameLength = chunk.frameLength

        let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, data) in chunk.buffers.enumerated() where index < destination.count {
            let audioBuffer = destination[index]
            data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress, let destinationBase = audioBuffer.mData else { return }
                memcpy(destinationBase, baseAddress, min(Int(audioBuffer.mDataByteSize), data.count))
            }
            destination[index].mDataByteSize = UInt32(chunk.byteSizes[index])
        }

        try? outputFile.write(from: buffer)
    }

    private func translateProcessID(_ processID: Int32) throws -> AudioObjectID {
        var pid = processID
        var result: AudioObjectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &pid,
                &dataSize,
                &result
            ),
            operation: "translate PID to process object"
        )
        return result
    }

    private func tapUID(for tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &tapUID),
            operation: "read tap UID"
        )
        return tapUID as String
    }

    private func tapFormat(for tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &asbd),
            operation: "read tap format"
        )
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw NSError(domain: "ProcessTapCapture", code: 72, userInfo: [NSLocalizedDescriptionKey: "The meeting app audio format is unsupported."])
        }
        return format
    }

    private func buildAggregateDeviceDescription(tapUID: String) throws -> [String: Any] {
        let aggregateUID = "com.meeting-recorder.aggregate.\(UUID().uuidString)"
        let tap: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: 1
        ]

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Recorder Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tap],
            kAudioAggregateDeviceTapAutoStartKey: 1
        ]

        if let outputDeviceUID = try defaultOutputDeviceUID() {
            description[kAudioAggregateDeviceClockDeviceKey] = outputDeviceUID
        }

        return description
    }

    private func defaultOutputDeviceUID() throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID()
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID),
            operation: "read default output device"
        )
        guard deviceID != .zero else {
            return nil
        }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        dataSize = UInt32(MemoryLayout<CFString>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &uid),
            operation: "read output device UID"
        )
        return uid as String
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "ProcessTapCapture", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Unable to \(operation). OSStatus \(status)."])
        }
    }

    private static func frameLength(for bufferList: UnsafePointer<AudioBufferList>) -> AVAudioFrameCount {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first else { return 0 }
        let bytesPerFrame = max(Int(first.mNumberChannels) * MemoryLayout<Float>.size, MemoryLayout<Float>.size)
        return AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
    }

    private static func averagePowerLevel(for bufferList: UnsafePointer<AudioBufferList>) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var sum: Float = 0
        var count: Int = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let pointer = data.bindMemory(to: Float.self, capacity: sampleCount)
            for index in 0 ..< sampleCount {
                let value = pointer[index]
                sum += value * value
            }
            count += sampleCount
        }

        guard count > 0 else { return 0 }
        return min(max(sqrt(sum / Float(count)) * 3.2, 0), 1)
    }
}

private struct CapturedAudioChunk: Sendable {
    let buffers: [Data]
    let byteSizes: [Int]
    let frameLength: AVAudioFrameCount

    static func copying(_ bufferList: UnsafePointer<AudioBufferList>, frameLength: AVAudioFrameCount) -> CapturedAudioChunk {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        return CapturedAudioChunk(
            buffers: buffers.map { buffer in
                guard let data = buffer.mData else { return Data() }
                return Data(bytes: data, count: Int(buffer.mDataByteSize))
            },
            byteSizes: buffers.map { Int($0.mDataByteSize) },
            frameLength: frameLength
        )
    }
}

private enum AudioMixer {
    static func mix(sourceURLs: [URL], outputURL: URL) throws {
        let readableURLs = sourceURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !readableURLs.isEmpty else {
            throw NSError(domain: "AudioMixer", code: 20, userInfo: [NSLocalizedDescriptionKey: "No audio sources were captured."])
        }

        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let states = try readableURLs.map { try MixingState(url: $0, outputFormat: outputFormat) }
        let frameChunk: AVAudioFrameCount = 2_048

        while true {
            let buffers = try states.map { try $0.readConvertedChunk(frameCount: frameChunk) }
            let maxFrameLength = buffers.map(\.frameLength).max() ?? 0
            if maxFrameLength == 0 {
                break
            }

            guard let mixedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: maxFrameLength) else {
                throw NSError(domain: "AudioMixer", code: 21, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate mixed audio buffer."])
            }
            mixedBuffer.frameLength = maxFrameLength

            let channelCount = Int(outputFormat.channelCount)
            for channelIndex in 0 ..< channelCount {
                guard let channelData = mixedBuffer.floatChannelData?[channelIndex] else { continue }
                for frameIndex in 0 ..< Int(maxFrameLength) {
                    channelData[frameIndex] = 0
                }
            }

            let gain = 0.8 / Float(max(buffers.count, 1))
            for buffer in buffers where buffer.frameLength > 0 {
                let inputChannels = Int(buffer.format.channelCount)
                for channelIndex in 0 ..< channelCount {
                    guard let outputChannel = mixedBuffer.floatChannelData?[channelIndex] else {
                        continue
                    }
                    let sourceChannelIndex = min(channelIndex, inputChannels - 1)
                    guard let inputChannel = buffer.floatChannelData?[sourceChannelIndex] else { continue }
                    for frameIndex in 0 ..< Int(buffer.frameLength) {
                        let sample = outputChannel[frameIndex] + (inputChannel[frameIndex] * gain)
                        outputChannel[frameIndex] = min(1, max(-1, sample))
                    }
                }
            }

            try outputFile.write(from: mixedBuffer)
        }

        readableURLs.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

private final class MixingState {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private var reachedEnd = false
    private var fedEOF = false

    init(url: URL, outputFormat: AVAudioFormat) throws {
        self.file = try AVAudioFile(forReading: url)
        self.sourceFormat = file.processingFormat
        self.outputFormat = outputFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw NSError(domain: "MixingState", code: 30, userInfo: [NSLocalizedDescriptionKey: "Unable to create converter for \(url.lastPathComponent)."])
        }
        self.converter = converter
    }

    func readConvertedChunk(frameCount: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "MixingState", code: 31, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate conversion buffer."])
        }
        if reachedEnd {
            outputBuffer.frameLength = 0
            return outputBuffer
        }

        let eofBox = EOFBox(value: fedEOF)
        var conversionError: NSError?
        let sourceFormat = self.sourceFormat
        let file = self.file
        let fedEOF = self.fedEOF
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if fedEOF || eofBox.value {
                outStatus.pointee = .endOfStream
                return nil
            }
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                outStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: inputBuffer, frameCount: frameCount)
            } catch {
                outStatus.pointee = .endOfStream
                eofBox.value = true
                return nil
            }

            if inputBuffer.frameLength == 0 {
                outStatus.pointee = .endOfStream
                eofBox.value = true
                return nil
            }

            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            throw conversionError
        }
        if status == .endOfStream {
            reachedEnd = true
            self.fedEOF = true
        }
        return outputBuffer
    }
}

private final class EOFBox: @unchecked Sendable {
    var value: Bool

    init(value: Bool) {
        self.value = value
    }
}

private extension CMSampleBuffer {
    var averagePowerLevel: Float? {
        let result = audioBufferList
        guard result.status == noErr else { return nil }
        defer {
            result.pointer.deallocate()
        }

        guard
            let description = CMSampleBufferGetFormatDescription(self),
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let flags = asbd.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let audioBuffer = result.pointer.pointee.mBuffers
        guard let data = audioBuffer.mData else { return nil }

        let sampleCount = sampleCountFor(bytes: Int(audioBuffer.mDataByteSize), bitsPerChannel: bitsPerChannel)
        guard sampleCount > 0 else { return nil }

        let rms: Float
        if isFloat && bitsPerChannel == 32 {
            rms = rootMeanSquare(data: data, count: sampleCount, type: Float.self, normalize: { $0 })
        } else if bitsPerChannel == 16 {
            rms = rootMeanSquare(data: data, count: sampleCount, type: Int16.self, normalize: { Float($0) / Float(Int16.max) })
        } else if bitsPerChannel == 32 {
            rms = rootMeanSquare(data: data, count: sampleCount, type: Int32.self, normalize: { Float($0) / Float(Int32.max) })
        } else {
            return nil
        }

        return min(max(rms * 3.2, 0), 1)
    }

    var audioBufferList: (pointer: UnsafeMutablePointer<AudioBufferList>, blockBuffer: CMBlockBuffer?, status: OSStatus) {
        let pointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: pointer,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        return (pointer, blockBuffer, status)
    }

    private func sampleCountFor(bytes: Int, bitsPerChannel: Int) -> Int {
        guard bitsPerChannel > 0 else { return 0 }
        return bytes / max(bitsPerChannel / 8, 1)
    }

    private func rootMeanSquare<T>(
        data: UnsafeMutableRawPointer,
        count: Int,
        type: T.Type,
        normalize: (T) -> Float
    ) -> Float {
        let pointer = data.bindMemory(to: T.self, capacity: count)
        var sum: Float = 0
        for index in 0 ..< count {
            let sample = normalize(pointer[index])
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }
}
