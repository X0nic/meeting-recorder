import Foundation
import AVFoundation
import AppKit

@MainActor
final class AudioDeviceService: ObservableObject {
    @Published private(set) var audioDevices: [AudioDevice] = []
    @Published private(set) var screenOptions: [ScreenOption] = []

    private let runner = ProcessRunner()

    func refresh() async {
        audioDevices = await loadAudioDevices()
        screenOptions = await loadScreens()
    }

    func defaultSystemAudio() -> AudioDevice? {
        audioDevices.first(where: { $0.isBlackHole }) ?? audioDevices.first
    }

    func defaultMic() -> AudioDevice? {
        audioDevices.first(where: { !$0.isBlackHole && $0.isMicrophone })
            ?? audioDevices.first(where: { !$0.isBlackHole })
            ?? audioDevices.first
    }

    private func loadAudioDevices() async -> [AudioDevice] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInMicrophone, .externalUnknown]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.microphone)
        }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices

        let ffmpegMap = (try? await ffmpegAudioDeviceIndexByName()) ?? [:]
        return devices.compactMap { device in
            let name = device.localizedName
            let isMicType: Bool = {
                if device.deviceType == .builtInMicrophone {
                    return true
                }
                if #available(macOS 14.0, *) {
                    return device.deviceType == .microphone
                }
                return false
            }()
            return AudioDevice(
                id: device.uniqueID,
                name: name,
                isBlackHole: name.localizedCaseInsensitiveContains("blackhole"),
                isMicrophone: name.localizedCaseInsensitiveContains("microphone") || name.localizedCaseInsensitiveContains("airpods") || isMicType,
                avFoundationIndex: ffmpegMap[name]
            )
        }
        .sorted { lhs, rhs in
            if lhs.isBlackHole != rhs.isBlackHole {
                return lhs.isBlackHole
            }
            return lhs.name < rhs.name
        }
    }

    private func loadScreens() async -> [ScreenOption] {
        let ffmpegScreens = (try? await ffmpegScreenIndexByCaptureNumber()) ?? [:]
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        return screens.enumerated().map { idx, screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(idx)
            return ScreenOption(
                displayID: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                ffmpegIndex: ffmpegScreens[idx]
            )
        }
    }

    private func ffmpegAudioDeviceIndexByName() async throws -> [String: Int] {
        let output = try await runner.run(["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""], allowFailure: true)
        return parseDeviceIndices(log: output.stderr + output.stdout, sectionToken: "AVFoundation audio devices")
    }

    private func ffmpegScreenIndexByCaptureNumber() async throws -> [Int: Int] {
        let output = try await runner.run(["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""], allowFailure: true)
        let map = parseDeviceIndices(log: output.stderr + output.stdout, sectionToken: "AVFoundation video devices")
        var out: [Int: Int] = [:]
        for (name, index) in map {
            if let capture = captureScreenNumber(from: name) {
                out[capture] = index
            }
        }
        return out
    }

    private func parseDeviceIndices(log: String, sectionToken: String) -> [String: Int] {
        var inSection = false
        var result: [String: Int] = [:]

        for raw in log.split(separator: "\n") {
            let line = String(raw)
            if line.contains(sectionToken) {
                inSection = true
                continue
            }
            if line.contains("AVFoundation") && !line.contains(sectionToken) && line.contains("devices") {
                inSection = false
                continue
            }
            guard inSection else { continue }

            guard let indexStart = line.range(of: "[")?.upperBound,
                  let indexEnd = line.range(of: "]")?.lowerBound,
                  let index = Int(line[indexStart..<indexEnd]) else {
                continue
            }
            if let rightBracket = line.range(of: "]")?.upperBound {
                let name = line[rightBracket...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    result[name] = index
                }
            }
        }

        return result
    }

    private func captureScreenNumber(from name: String) -> Int? {
        let prefix = "Capture screen "
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }
}
