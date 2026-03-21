import SwiftUI
import AppKit

@main
struct MeetingRecorderApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .background(WindowConfigurator())
        }
        .commands {
            CommandMenu("Meeting Recorder") {
                Button("Open Recording…") {
                    model.presentFileImporter()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.title = "Meeting Recorder"
            window.setContentSize(NSSize(width: 460, height: 560))
            window.minSize = NSSize(width: 430, height: 520)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
