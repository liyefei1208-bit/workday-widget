import SwiftUI

enum Theme {
    static let accent = Color(red: 0.20, green: 0.80, blue: 0.47)
    static let rest = Color(red: 0.64, green: 0.57, blue: 0.99)
    static let overtime = Color(red: 1.00, green: 0.58, blue: 0.20)

    static let ringOverall = Color(red: 0.20, green: 0.80, blue: 0.47)
    static let ringMorning = Color(red: 1.00, green: 0.69, blue: 0.26)
    static let ringAfternoon = Color(red: 0.35, green: 0.62, blue: 1.00)

    static func statusColor(_ phase: DayPhase) -> Color {
        switch phase {
        case .working: return accent
        case .lunchBreak, .dinnerBreak: return .orange
        case .beforeWork: return .blue
        case .afterWork: return .secondary
        case .overtime: return overtime
        case .weekend: return rest
        }
    }

    static func overallTint(_ phase: DayPhase) -> Color {
        phase == .overtime ? overtime : ringOverall
    }
}

// MARK: - Circular progress

/// Large circular completion ring.
struct ProgressRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 10
    var trackColor: Color = Color.primary.opacity(0.09)

    var body: some View {
        let value = progress.clamped(to: 0...1)
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: value)
                .stroke(
                    LinearGradient(
                        colors: [tint.opacity(0.68), tint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.55), value: value)
    }
}

/// Small circular completion ring used for the morning / afternoon segments.
struct MiniRing: View {
    var progress: Double
    var tint: Color
    var size: CGFloat = 36
    var lineWidth: CGFloat = 5
    var trackColor: Color = Color.primary.opacity(0.09)

    var body: some View {
        let value = progress.clamped(to: 0...1)
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: value)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.55), value: value)
    }
}

// MARK: - Glass background

/// Glass background that mirrors the macOS widget look.
struct WidgetBackground: View {
    var preview: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack {
            if preview {
                shape.fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color(red: 0.15, green: 0.17, blue: 0.21),
                               Color(red: 0.07, green: 0.08, blue: 0.11)]
                            : [Color(white: 0.99), Color(white: 0.91)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            } else {
                shape.fill(.ultraThinMaterial)
            }

            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(scheme == .dark ? 0.07 : 0.45),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            )

            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(scheme == .dark ? 0.18 : 0.85),
                        Color.white.opacity(0.03)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.8
            )
        }
    }
}
