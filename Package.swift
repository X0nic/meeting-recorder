// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
        .executable(name: "NativeAudioProbe", targets: ["NativeAudioProbe"])
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            path: "Sources/MeetingRecorder"
        ),
        .executableTarget(
            name: "NativeAudioProbe",
            path: "Sources/NativeAudioProbe"
        )
    ]
)
