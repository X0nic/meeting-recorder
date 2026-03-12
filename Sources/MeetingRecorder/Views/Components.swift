import SwiftUI

enum RecorderTheme {
    static let windowTop = Color(red: 0.06, green: 0.08, blue: 0.11)
    static let windowBottom = Color(red: 0.13, green: 0.17, blue: 0.22)
    static let cardFill = Color(red: 0.15, green: 0.19, blue: 0.25)
    static let badgeFill = Color(red: 0.21, green: 0.26, blue: 0.33)
    static let meterFill = Color(red: 0.09, green: 0.12, blue: 0.16)
    static let meterTrack = Color.white.opacity(0.18)
    static let primaryText = Color.white
    static let secondaryText = Color(red: 0.78, green: 0.84, blue: 0.90)
    static let border = Color.white.opacity(0.10)
}

struct StatusBadge: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(RecorderTheme.secondaryText)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(RecorderTheme.primaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(RecorderTheme.badgeFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(RecorderTheme.border, lineWidth: 1)
                )
        )
    }
}

struct AudioLevelMeterView: View {
    let title: String
    let subtitle: String
    let level: Float
    let tint: Color
    let activityText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(RecorderTheme.primaryText)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(RecorderTheme.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                Text("\(Int(level * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(RecorderTheme.primaryText)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(RecorderTheme.meterTrack)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.45), tint, .white.opacity(0.9)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(10, proxy.size.width * CGFloat(level)))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(height: 18)

            Text(activityText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(RecorderTheme.secondaryText)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(RecorderTheme.meterFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(RecorderTheme.border, lineWidth: 1)
                )
        )
    }
}

struct SetupStatusRow: View {
    let title: String
    let status: SetupStatus
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(RecorderTheme.primaryText)
                    Text(status.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(statusColor)
                }
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(RecorderTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.link)
                }
            }
            Spacer()
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted:
            return .green
        case .missing:
            return .orange
        case .unknown:
            return .yellow
        }
    }
}

struct ProcessingProgressView: View {
    let title: String
    let progress: Double
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(RecorderTheme.primaryText)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(RecorderTheme.primaryText)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RecorderTheme.meterTrack)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.24, green: 0.68, blue: 0.66),
                                    Color(red: 0.94, green: 0.70, blue: 0.28)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(progress > 0 ? 12 : 0, proxy.size.width * progress))
                        .animation(.easeInOut(duration: 0.2), value: progress)
                }
            }
            .frame(height: 14)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(RecorderTheme.secondaryText)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(RecorderTheme.meterFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(RecorderTheme.border, lineWidth: 1)
                )
        )
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(RecorderTheme.secondaryText)
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(RecorderTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(RecorderTheme.border, lineWidth: 1)
                )
        )
    }
}
