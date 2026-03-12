import SwiftUI

@main
struct MeetingRecorderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Meeting Recorder") {
            MainWindowView(model: model)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Recording File…") {
                    model.isFileImporterPresented = true
                }
                .keyboardShortcut("o")
            }
        }
    }
}
