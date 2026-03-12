import AppKit
import CoreAudio
import Foundation

struct MeetingDetector {
    private let supportedAppNames: Set<String> = [
        "MSTeams",
        "Microsoft Teams",
        "zoom.us",
        "Google Chrome",
        "Slack",
        "Webex",
        "FaceTime"
    ]

    func detectMeetings() -> [MeetingAppPresence] {
        let outputProcesses = audioOutputProcesses()
        let runningAppsByPID = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.compactMap { app -> (Int32, NSRunningApplication)? in
                guard let localizedName = app.localizedName, supportedAppNames.contains(localizedName) else {
                    return nil
                }
                return (app.processIdentifier, app)
            }
        )

        var results: [MeetingAppPresence] = []
        var seenProcessIDs = Set<Int32>()

        if let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in windowInfo {
                guard
                    let ownerName = info[kCGWindowOwnerName as String] as? String,
                    supportedAppNames.contains(ownerName),
                    let ownerPID = info[kCGWindowOwnerPID as String] as? Int32
                else {
                    continue
                }

                let title = info[kCGWindowName as String] as? String
                let runningApp = runningAppsByPID[ownerPID]
                let audioPID = resolvedAudioProcessID(
                    for: runningApp,
                    fallbackPID: ownerPID,
                    outputProcesses: outputProcesses
                )
                results.append(
                    MeetingAppPresence(
                        id: "\(audioPID)-\(title ?? ownerName)",
                        appName: ownerName,
                        bundleID: runningApp?.bundleIdentifier,
                        processID: ownerPID,
                        audioProcessID: audioPID,
                        windowTitle: title
                    )
                )
                seenProcessIDs.insert(ownerPID)
            }
        }

        for runningApp in runningAppsByPID.values where !seenProcessIDs.contains(runningApp.processIdentifier) {
            let audioPID = resolvedAudioProcessID(
                for: runningApp,
                fallbackPID: runningApp.processIdentifier,
                outputProcesses: outputProcesses
            )
            results.append(
                MeetingAppPresence(
                    id: "\(audioPID)-\(runningApp.localizedName ?? "meeting-app")",
                    appName: runningApp.localizedName ?? runningApp.bundleIdentifier ?? "Meeting App",
                    bundleID: runningApp.bundleIdentifier,
                    processID: runningApp.processIdentifier,
                    audioProcessID: audioPID,
                    windowTitle: nil
                )
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.appName != rhs.appName {
            return lhs.appName < rhs.appName
        }
            return lhs.audioProcessID < rhs.audioProcessID
        }
    }

    private func audioOutputProcesses() -> [AudioOutputProcess] {
        guard #available(macOS 15.0, *) else {
            return []
        }

        return (try? AudioHardwareSystem.shared.processes.compactMap { process in
            guard try process.isRunningOutput else {
                return nil
            }
            return AudioOutputProcess(
                pid: try process.pid,
                bundleID: try process.bundleID,
                name: try process.name
            )
        }) ?? []
    }

    private func resolvedAudioProcessID(
        for runningApp: NSRunningApplication?,
        fallbackPID: Int32,
        outputProcesses: [AudioOutputProcess]
    ) -> Int32 {
        guard let runningApp else {
            return fallbackPID
        }

        if let bundleID = runningApp.bundleIdentifier {
            if let exactBundleMatch = outputProcesses.first(where: { $0.bundleID == bundleID }) {
                return exactBundleMatch.pid
            }

            let bundlePrefix = bundleID + "."
            if let helperBundleMatch = outputProcesses.first(where: { ($0.bundleID?.hasPrefix(bundlePrefix) ?? false) }) {
                return helperBundleMatch.pid
            }
        }

        if let localizedName = runningApp.localizedName {
            let normalizedName = localizedName.replacingOccurrences(of: " ", with: "").lowercased()
            if let nameMatch = outputProcesses.first(where: {
                $0.name.replacingOccurrences(of: " ", with: "").lowercased().contains(normalizedName)
            }) {
                return nameMatch.pid
            }
        }

        return fallbackPID
    }
}

private struct AudioOutputProcess {
    let pid: Int32
    let bundleID: String?
    let name: String
}
