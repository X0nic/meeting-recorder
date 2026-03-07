import Foundation
import AppKit

@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var matches: [MeetingAppMatch] = []
    @Published private(set) var recommendedScreenID: CGDirectDisplayID?

    private let meetingProcessNames: Set<String> = [
        "MSTeams", "Microsoft Teams", "zoom.us", "Slack", "Webex", "FaceTime"
    ]

    func refresh(screenOptions: [ScreenOption]) {
        let windows = visibleWindows()
        let runningApps = NSWorkspace.shared.runningApplications
        let appNames = Set(runningApps.compactMap(\.localizedName) + runningApps.compactMap(\.bundleIdentifier))

        var found: [(String, ScreenOption)] = []

        for app in appNames where isMeetingApp(app) {
            if app.contains("Chrome") {
                continue
            }
            if let screen = bestScreen(for: windows, owner: app, options: screenOptions) {
                found.append((displayAppName(app), screen))
            }
        }

        let chromeWindows = windows.filter {
            let owner = ($0[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (($0[kCGWindowName as String] as? String) ?? "").lowercased()
            return owner.contains("Chrome") && title.contains("meet.google.com")
        }

        if let first = chromeWindows.first,
           let frame = windowFrame(first),
           let screen = overlappingScreen(for: frame, options: screenOptions) {
            found.append(("Google Meet", screen))
        }

        matches = found.map { MeetingAppMatch(appName: $0.0, screenName: $0.1.name) }

        let grouped = Dictionary(grouping: found, by: { $0.1.displayID })
        recommendedScreenID = grouped.max(by: { $0.value.count < $1.value.count })?.key
    }

    private func visibleWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    private func isMeetingApp(_ app: String) -> Bool {
        if meetingProcessNames.contains(app) {
            return true
        }
        let normalized = app.lowercased()
        return normalized.contains("teams") || normalized.contains("zoom") || normalized.contains("webex") || normalized.contains("facetime")
    }

    private func displayAppName(_ raw: String) -> String {
        if raw == "MSTeams" || raw == "Microsoft Teams" {
            return "Microsoft Teams"
        }
        return raw
    }

    private func bestScreen(for windows: [[String: Any]], owner: String, options: [ScreenOption]) -> ScreenOption? {
        let ownerWindows = windows.filter {
            (($0[kCGWindowOwnerName as String] as? String) ?? "").localizedCaseInsensitiveContains(owner)
        }
        guard !ownerWindows.isEmpty else { return nil }

        let scored: [(ScreenOption, CGFloat)] = ownerWindows.compactMap { info in
            guard let frame = windowFrame(info), let screen = overlappingScreen(for: frame, options: options) else {
                return nil
            }
            return (screen, frame.width * frame.height)
        }

        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    private func windowFrame(_ info: [String: Any]) -> CGRect? {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? CGFloat,
              let y = bounds["Y"] as? CGFloat,
              let w = bounds["Width"] as? CGFloat,
              let h = bounds["Height"] as? CGFloat else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func overlappingScreen(for frame: CGRect, options: [ScreenOption]) -> ScreenOption? {
        options.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
