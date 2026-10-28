import SwiftUI
import AppKit

struct WidgetWindowRoot: View {
    @ObservedObject var model: WorkdayModel
    var preview: Bool = false

    var body: some View {
        WidgetView(model: model, preview: preview)
            .padding(20) // room for the soft drop shadow
    }
}

struct WidgetView: View {
    @ObservedObject var model: WorkdayModel
    var preview: Bool = false

    var body: some View {
        let snap = model.snapshot

        VStack(alignment: .leading, spacing: 0) {
            header(snap)

            if snap.isWorkday {
                Spacer(minLength: 12)
                mainProgress(snap)
                Spacer(minLength: 14)
                divider
                Spacer(minLength: 12)
            } else {
                Spacer(minLength: 12)
                restState(snap)
                Spacer(minLength: 12)
            }

            footer(snap)

            Spacer(minLength: 8)

            watermark
        }
        .padding(18)
        .frame(width: 292, height: 260, alignment: .topLeading)
        .background(WidgetBackground(preview: preview))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
        .contextMenu {
            Button("设置…") {
                NotificationCenter.default.post(name: .workdayOpenSettings, object: nil)
            }
            Button("隐藏桌面组件") {
                NotificationCenter.default.post(name: .workdayToggleDesktop, object: nil)
            }
            Divider()
            Button("退出工作日") {
                NSApp.terminate(nil)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            snap.isWorkday
                ? "工作日已完成 \(snap.percentOverall)%，上午已完成 \(snap.percentMorning)%，下午已完成 \(snap.percentAfternoon)%"
                : "今天是休息日"
        )
    }

    // MARK: - Header

    private func header(_ snap: DaySnapshot) -> some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.statusColor(snap.phase).opacity(0.16))
                Image(systemName: snap.isWorkday ? "briefcase.fill" : "moon.stars.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.statusColor(snap.phase))
            }
            .frame(width: 27, height: 27)

            VStack(alignment: .leading, spacing: 1) {
                Text(snap.isWorkday ? "工作日" : "今日")
                    .font(.system(size: 13, weight: .semibold))
                Text(TimeFormat.range(snap.settings.workStart, snap.settings.workEnd))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(TimeFormat.clock(snap.now))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Main progress

    private func mainProgress(_ snap: DaySnapshot) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                ProgressRing(
                    progress: snap.overallProgress,
                    tint: Theme.overallTint(snap.phase),
                    lineWidth: 10
                )

                VStack(spacing: 0) {
                    Text("\(snap.percentOverall)%")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                    Text("已完成")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 100)

            VStack(alignment: .leading, spacing: 16) {
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
    }

    private func segmentRow(
        icon: String,
        title: String,
        range: String,
        progress: Double,
        percent: Int,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            MiniRing(progress: progress, tint: tint, size: 34, lineWidth: 5)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                }
                Text(range)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(percent)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Footer

    private func footer(_ snap: DaySnapshot) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.statusColor(snap.phase))
                .frame(width: 6, height: 6)
                .shadow(color: Theme.statusColor(snap.phase).opacity(0.6), radius: 3)

            Text(snap.phase.title)
                .font(.system(size: 11, weight: .semibold))

            Spacer(minLength: 4)

            Text(detailText(snap))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(snap.phase == .overtime ? Theme.overtime : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
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

    // MARK: - Weekend

    private func restState(_ snap: DaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text("休息日")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                Spacer()
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Theme.rest)
            }

            Text("今天不用上班，放松一下吧")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("下一个工作日")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(TimeFormat.nextWorkdayLabel(from: snap.now, workStart: snap.settings.workStart))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }

    /// Author watermark. Deliberately low-contrast so it never competes with
    /// the progress readout.
    private var watermark: some View {
        Text(AppInfo.watermark)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(.primary.opacity(0.24))
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
    }
}
