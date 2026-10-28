import SwiftUI

/// Artwork for the app icon, rendered offscreen by `--render-icon` and then
/// turned into an `.icns` by `build.sh`.
///
/// Drawn on a 1024pt canvas with the macOS-standard inset so the squircle does
/// not touch the edges.
struct AppIconView: View {
    /// Progress shown on the icon's ring. A value that reads clearly at 16pt.
    var progress: Double = 0.68

    private let canvas: CGFloat = 1024
    private var inset: CGFloat { canvas * 0.094 }
    private var side: CGFloat { canvas - inset * 2 }

    var body: some View {
        ZStack {
            Color.clear

            ZStack {
                // Squircle body.
                RoundedRectangle(cornerRadius: side * 0.232, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.19, green: 0.21, blue: 0.26),
                                Color(red: 0.07, green: 0.08, blue: 0.11),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Top sheen.
                RoundedRectangle(cornerRadius: side * 0.232, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                ring
            }
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.28), radius: side * 0.03, x: 0, y: side * 0.018)
        }
        .frame(width: canvas, height: canvas)
    }

    private var ring: some View {
        let ringSize = side * 0.60
        let lineWidth = side * 0.095

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.13), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.36, green: 0.89, blue: 0.58),
                            Color(red: 0.13, green: 0.72, blue: 0.42),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: "briefcase.fill")
                .font(.system(size: ringSize * 0.40, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: ringSize, height: ringSize)
    }
}
