import SwiftUI

@main
struct NativeAudioProbeApp: App {
    var body: some Scene {
        WindowGroup("Native Audio Probe") {
            AudioTestView()
        }
        .defaultSize(width: 760, height: 760)
        .windowResizability(.contentSize)
    }
}
