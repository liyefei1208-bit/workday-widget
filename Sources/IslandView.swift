import SwiftUI
import AppKit

// MARK: - Screen metrics

/// Physical notch / menu-bar metrics for a single screen.
///
/// On a MacBook with a notch the collapsed island is sized to the notch itself,
/// so the hardware cutout covers it completely. On a display without a notch
/// there is nothing to hide behind, so a small pill is shown instead.
struct IslandMetrics: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// Horizontal offset of the notch centre from the screen centre. The
    /// hardware cutout is not always exactly centred, and being off by even a
    /// point leaves a sliver of the island showing beside it.
    var centerOffset: CGFloat

    init(
        hasNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        centerOffset: CGFloat = 0
    ) {
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.centerOffset = centerOffset
    }

    init(screen: NSScreen) {
        let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX - left.maxX > 80 {
            hasNotch = true
            notchWidth = right.minX - left.maxX
            notchHeight = screen.safeAreaInsets.top
            centerOffset = (left.maxX + right.minX) / 2 - screen.frame.midX
        } else {
            hasNotch = false
            notchWidth = IslandLayout.pillBodyWidth
            notchHeight = menuBarHeight
            centerOffset = 0
        }
    }

    /// Used by `--render` previews, which must not depend on the live display.
    static let previewNotch = IslandMetrics(hasNotch: true, notchWidth: 185, notchHeight: 32)
}

// MARK: - Layout

enum IslandLayout {
    /// Radius of the concave fillets where the island meets the screen edge.
    static let flare: CGFloat = 9
    static let collapsedBottomRadius: CGFloat = 10
    static let expandedBottomRadius: CGFloat = 22

    /// Body width of the collapsed pill on displays without a notch.
    static let pillBodyWidth: CGFloat = 190
    static let expandedBodyWidth: CGFloat = 320
    /// Sized to the detail content itself, so the footer row sits right under
    /// the rings instead of being pushed down by leftover space.
    static let detailHeight: CGFloat = 130

    /// Transparent margin around the island for its drop shadow.
    static let shadowPadding: CGFloat = 24
    /// Extra grab area below the collapsed island so hovering is forgiving.
    static let hoverPadding: CGFloat = 5

    /// Collapsed size. On a notch display this matches the notch exactly, so
    /// nothing is visible outside the hardware cutout.
    static func collapsedSize(_ m: IslandMetrics) -> CGSize {
        m.hasNotch
            ? CGSize(width: m.notchWidth, height: m.notchHeight)
            : CGSize(width: m.notchWidth + 2 * flare, height: m.notchHeight)
    }

    static func expandedSize(_ m: IslandMetrics) -> CGSize {
        CGSize(
            width: expandedBodyWidth + 2 * flare,
            height: m.notchHeight + detailHeight
        )
    }

    /// Fixed panel size — large enough for the expanded island plus shadow.
    /// The window is never resized while animating.
    static func windowSize(_ m: IslandMetrics) -> CGSize {
        let open = expandedSize(m)
        return CGSize(
            width: open.width + 2 * shadowPadding,
            height: open.height + shadowPadding
        )
    }

    /// Island rect inside the panel, in AppKit (bottom-left origin) coordinates.
    /// The island is pinned to the top edge of the window.
    static func islandRect(expanded: Bool, metrics: IslandMetrics) -> NSRect {
        let window = windowSize(metrics)
        let size = expanded ? expandedSize(metrics) : collapsedSize(metrics)
        return NSRect(
            x: (window.width - size.width) / 2,
            y: window.height - size.height,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Shape

/// The notch silhouette: a full-width top edge flush with the screen bezel,
/// concave fillets blending into the menu bar, and rounded bottom corners.
///
/// The vertical sides sit `flare` inset from the rect, so the visible body is
/// `rect.width - 2 * flare` wide while the top edge spans the whole rect.
struct NotchIslandShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set {
            flare = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(flare, rect.width / 2))
        let br = max(0, min(bottomRadius, min(rect.width / 2 - f, rect.height - f)))

        var path = Path()

        // Top-left: start at the screen edge and curve down into the body.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + f, y: rect.minY + f),
            control: CGPoint(x: rect.minX + f, y: rect.minY)
        )

        // Left side down to the bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + f + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + f, y: rect.maxY)
        )

        // Bottom edge and bottom-right corner.
        path.addLine(to: CGPoint(x: rect.maxX - f - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - f, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - f, y: rect.maxY)
        )

        // Right side back up, then curve out to the screen edge.
        path.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - f, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

// MARK: - State

/// Expansion / pin state for the island.
///
/// Three things can hold the island open: the pointer hovering it, a manual
/// pin, and a reminder that is currently being shown.
final class IslandState: ObservableObject {
    @Published private(set) var isHovering = false
    @Published private(set) var isPinned = false
    /// The reminder currently on display, if any. Non-nil forces expansion.
    @Published private(set) var reminder: Reminder?
    @Published private(set) var expanded = false

    func setHovering(_ value: Bool) {
        guard isHovering != value else { return }
        isHovering = value
        refresh()
    }

    func togglePinned() {
        isPinned.toggle()
        refresh()
    }

    func unpin() {
        guard isPinned else { return }
        isPinned = false
        refresh()
    }

    // MARK: Reminders

    func showReminder(_ reminder: Reminder) {
        self.reminder = reminder
        refresh()
    }

    func dismissReminder() {
        guard reminder != nil else { return }
        reminder = nil
        refresh()
    }

    private func refresh() {
        let next = isPinned || isHovering || reminder != nil
        if next != expanded { expanded = next }
    }
}

// MARK: - Root

struct IslandRoot: View {
    @ObservedObject var model: WorkdayModel
    @ObservedObject var state: IslandState
    var metrics: IslandMetrics
    var preview: Bool = false

    var body: some View {
        if preview {
            // Draw a stand-in menu bar + hardware notch so the preview shows
            // how the island reads against the real screen edge.
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(Color(white: 0.28))
                        .frame(height: metrics.notchHeight)

                    IslandView(model: model, state: state, metrics: metrics)
                }
                .frame(width: IslandLayout.windowSize(metrics).width, alignment: .top)

                Spacer(minLength: 0)
            }
            .frame(
                width: IslandLayout.windowSize(metrics).width,
                height: IslandLayout.windowSize(metrics).height,
                alignment: .top
            )
            .background(Color(white: 0.16))
        } else {
            // The panel is a fixed size; the island is pinned to its top edge
            // so it lines up with the physical screen bezel.
            IslandView(model: model, state: state, metrics: metrics)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Island

struct IslandView: View {
    @ObservedObject var model: WorkdayModel
    @ObservedObject var state: IslandState
    var metrics: IslandMetrics

    var body: some View {
        let snap = model.snapshot
        let expanded = state.expanded
        let open = IslandLayout.expandedSize(metrics)
        let size = expanded ? open : IslandLayout.collapsedSize(metrics)

        let shape = NotchIslandShape(
            flare: IslandLayout.flare,
            bottomRadius: expanded
                ? IslandLayout.expandedBottomRadius
                : IslandLayout.collapsedBottomRadius
        )

        let animation: Animation = expanded
            ? .spring(response: 0.42, dampingFraction: 0.8)
            : .spring(response: 0.45, dampingFraction: 1.0)

        // One fixed-size content tree. Collapsing shrinks the island frame and
        // the shape clips everything that no longer fits — the detail never
        // moves, so there is nothing to re-lay-out mid-animation.
        VStack(spacing: 0) {
            topBand(snap)
                .frame(width: open.width, height: metrics.notchHeight)

            detailContent(snap)
                .frame(width: open.width, height: IslandLayout.detailHeight)
        }
        .frame(width: open.width, height: open.height, alignment: .top)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .shadow(
            color: .black.opacity(expanded ? 0.45 : 0),
            radius: expanded ? 14 : 0,
            x: 0,
            y: expanded ? 6 : 0
        )
        .animation(animation, value: expanded)
        .contentShape(shape)
        .onTapGesture {
            // While a reminder is up, a click dismisses it rather than pinning.
            if state.reminder != nil {
                state.dismissReminder()
            } else {
                state.togglePinned()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    guard state.reminder != nil else { return }
                    if value.translation.height < -20 {
                        state.dismissReminder()
                    }
                }
        )
        .contextMenu {
            Button(state.isPinned ? "取消固定" : "固定展开") { state.togglePinned() }
            Button("设置…") {
                NotificationCenter.default.post(name: .workdayOpenSettings, object: nil)
            }
            Button("隐藏灵动岛") {
                NotificationCenter.default.post(name: .workdayToggleIsland, object: nil)
            }
            Divider()
            Button("退出工作日") { NSApp.terminate(nil) }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(snap))
    }

    // MARK: Top band (level with the notch / menu bar)

    /// The band that sits at the screen edge. Its centre is reserved: on a
    /// notch display the hardware cutout covers it, so nothing is drawn there.
    private func topBand(_ snap: DaySnapshot) -> some View {
        let reserve = metrics.hasNotch
            ? metrics.notchWidth
            : IslandLayout.pillBodyWidth

        return HStack(spacing: 0) {
            Group {
                if state.expanded {
                    Text(snap.isWorkday ? snap.phase.title : "休息日")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .padding(.leading, IslandLayout.flare + 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Centre: hidden behind the hardware notch, or the compact pill
            // content on displays that have no notch.
            Group {
                if metrics.hasNotch {
                    Color.clear
                } else {
                    compactContent(snap)
                }
            }
            .frame(width: reserve)

            Group {
                if state.expanded {
                    HStack(spacing: 5) {
                        if state.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Text(TimeFormat.clock(snap.now))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.trailing, IslandLayout.flare + 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Compact readout, only used on displays without a physical notch.
    private func compactContent(_ snap: DaySnapshot) -> some View {
        HStack(spacing: 8) {
            if snap.isWorkday {
                MiniRing(
                    progress: snap.overallProgress,
                    tint: Theme.overallTint(snap.phase),
                    size: 17,
                    lineWidth: 3,
                    trackColor: Color.white.opacity(0.16)
                )

                Text("\(snap.percentOverall)%")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.rest)

                Text("休息日")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Circle()
                .fill(Theme.statusColor(snap.phase))
                .frame(width: 5, height: 5)
        }
    }

    // MARK: Detail content (revealed as the island grows)

    private func detailContent(_ snap: DaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let reminder = state.reminder {
                reminderContent(reminder, snap: snap)
            } else if snap.isWorkday {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        ProgressRing(
                            progress: snap.overallProgress,
                            tint: Theme.overallTint(snap.phase),
                            lineWidth: 8,
                            trackColor: Color.white.opacity(0.12)
                        )

                        VStack(spacing: 0) {
                            Text("\(snap.percentOverall)%")
                                .font(.system(size: 21, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.62)
                            Text("已完成")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    .frame(width: 86, height: 86)

                    VStack(alignment: .leading, spacing: 12) {
                        segmentRow(
                            icon: "sunrise.fill",
                            title: "上午",
                            range: snap.morningRangeLabel,
                            progress: snap.morningProgress,
                            percent: snap.percentMorning,
                            tint: Theme.ringMorning
                        )
                        segmentRow(
                            icon: "sun.max.fill",
                            title: "下午",
                            range: snap.afternoonRangeLabel,
                            progress: snap.afternoonProgress,
                            percent: snap.percentAfternoon,
                            tint: Theme.ringAfternoon
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    Text(detailText(snap))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(
                            snap.phase == .overtime
                                ? Theme.overtime
                                : .white.opacity(0.5)
                        )

                    Spacer(minLength: 4)

                    Text(trailingText(snap))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(
                            snap.phase == .overtime
                                ? Theme.overtime.opacity(0.8)
                                : .white.opacity(0.42)
                        )
                }
            } else {
                restContent(snap)
            }
        }
        .padding(.horizontal, IslandLayout.flare + 12)
        .padding(.top, 8)
        .padding(.bottom, 11)
        .frame(
            width: IslandLayout.expandedSize(metrics).width,
            height: IslandLayout.detailHeight,
            alignment: .topLeading
        )
    }

    /// Reminder card, shown instead of the progress detail while a reminder is
    /// on screen. Same geometry as the normal detail so the island animation
    /// does not change shape.
    private func reminderContent(_ reminder: Reminder, snap: DaySnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(reminder.kind.tint.opacity(0.18))
                Image(systemName: reminder.kind.icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(reminder.kind.tint)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(reminder.title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if !reminder.message.isEmpty {
                    Text(reminder.message)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                    Text("上滑收起")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.28))
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func segmentRow(
        icon: String,
        title: String,
        range: String,
        progress: Double,
        percent: Int,
        tint: Color
    ) -> some View {
        HStack(spacing: 9) {
            MiniRing(
                progress: progress,
                tint: tint,
                size: 28,
                lineWidth: 4,
                trackColor: Color.white.opacity(0.13)
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize()
                }
                Text(range)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(percent)%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 34, alignment: .trailing)
        }
    }

    private func restContent(_ snap: DaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("休息日")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("今天不用上班，放松一下吧")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))

            Spacer(minLength: 6)

            HStack {
                Text("下一个工作日")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(TimeFormat.nextWorkdayLabel(from: snap.now, workStart: snap.settings.workStart))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Copy

    private func accessibilityText(_ snap: DaySnapshot) -> String {
        if let reminder = state.reminder {
            return "\(reminder.title)。\(reminder.message)。上滑收起"
        }
        return snap.isWorkday
            ? "工作日已完成 \(snap.percentOverall)%"
            : "今天是休息日"
    }

    private func detailText(_ snap: DaySnapshot) -> String {
        switch snap.phase {
        case .weekend:
            return "好好休息"
        case .beforeWork:
            return "距上班 \(TimeFormat.duration(snap.minutesUntilWorkStart))"
        case .working, .lunchBreak, .dinnerBreak:
            return "已工作 \(TimeFormat.duration(snap.elapsedWork))"
        case .afterWork:
            return "今天辛苦了"
        case .overtime:
            return "已加班 \(TimeFormat.duration(snap.overtimeMinutes))"
        }
    }

    private func trailingText(_ snap: DaySnapshot) -> String {
        switch snap.phase {
        case .beforeWork:
            return "共 \(TimeFormat.duration(snap.totalWork))"
        case .working, .lunchBreak, .dinnerBreak:
            return "剩余 \(TimeFormat.duration(snap.remainingWork))"
        case .overtime:
            return "注意休息"
        case .afterWork, .weekend:
            return ""
        }
    }
}
