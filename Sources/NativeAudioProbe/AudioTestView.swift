import SwiftUI

struct AudioTestView: View {
    @StateObject private var service = AudioTestService()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Result") {
                HStack {
                    Text("ScreenCaptureKit verdict")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(service.backendVerdict.rawValue)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(verdictColor.opacity(0.18))
                        .clipShape(Capsule())
                }
            }

            GroupBox("Controls") {
                HStack(spacing: 12) {
                    Button("Check Permissions") {
                        Task {
                            await service.requestPermissionsOnly()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.runState == .starting || service.runState == .running)

                    Button("Start Test") {
                        Task {
                            await service.startTest()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.runState == .starting || service.runState == .running)

                    Button("Stop Test") {
                        Task {
                            await service.stopTest()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.runState != .starting && service.runState != .running)

                    Button("Open Output Folder") {
                        service.openOutputFolder()
                    }
                    .buttonStyle(.bordered)
                    .disabled(service.outputPaths == nil)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("Microphone", selection: $service.selectedMicrophoneID) {
                ForEach(service.microphones) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .disabled(service.runState == .starting || service.runState == .running)

            GroupBox("Meters") {
                VStack(alignment: .leading, spacing: 12) {
                    MeterRow(title: "System Audio", value: service.systemAudioLevel)
                    MeterRow(title: "Microphone", value: service.microphoneLevel)
                }
            }

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 8) {
                    KeyValueRow(label: "Run State", value: service.runState.rawValue)
                    KeyValueRow(label: "Verdict", value: service.backendVerdict.rawValue)
                    KeyValueRow(label: "Backend", value: service.backendStatus)
                    KeyValueRow(label: "Screen Permission", value: service.permissions.screenRecording.rawValue)
                    KeyValueRow(label: "Mic Permission", value: service.permissions.microphone.rawValue)
                    KeyValueRow(label: "Stream Started", value: yesNo(service.streamStarted))
                    KeyValueRow(label: "First System Frame", value: yesNo(service.didReceiveSystemAudio))
                    KeyValueRow(label: "First Mic Frame", value: yesNo(service.didReceiveMicrophoneAudio))
                    KeyValueRow(label: "System Format", value: service.systemAudioFormat)
                    KeyValueRow(label: "Mic Format", value: service.microphoneAudioFormat)
                    KeyValueRow(label: "Output Folder", value: service.outputPaths?.folderURL.path ?? "Not created")
                }
            }

            GroupBox("Last Error") {
                Text(service.lastError ?? "None")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(service.lastError == nil ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }

            GroupBox("Status Log") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(service.statusEvents) { event in
                            Text("[\(event.timestampText)] \(event.message)")
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 680)
        .task {
            service.initialize()
        }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private var verdictColor: Color {
        switch service.backendVerdict {
        case .pending:
            return .orange
        case .viable:
            return .green
        case .nonViable:
            return .red
        }
    }
}

private struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private struct MeterRow: View {
    let title: String
    let value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.18))
                    RoundedRectangle(cornerRadius: 8)
                        .fill(value > 0.8 ? Color.red : Color.accentColor)
                        .frame(width: max(proxy.size.width * CGFloat(value), value > 0 ? 4 : 0))
                }
            }
            .frame(height: 16)
        }
    }
}
