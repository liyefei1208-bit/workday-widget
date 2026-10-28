import AppKit
import SwiftUI

/// Work-time statistics: summary for the selected range plus one row per
/// finished workday.
struct StatsView: View {
    @ObservedObject var model: WorkdayModel
    @ObservedObject var log: WorkLog

    /// Rendered offscreen by `--render-stats`; see `content`.
    private let preview: Bool

    @State private var range: StatsRange

    init(
        model: WorkdayModel,
        log: WorkLog,
        initialRange: StatsRange = .week,
        preview: Bool = false
    ) {
        self.model = model
        self.log = log
        self.preview = preview
        _range = State(initialValue: initialRange)
    }

    private var summary: WorkLogSummary {
        log.summary(in: range, now: model.now)
    }

    private var rows: [WorkDayRecord] {
        log.records(in: range, now: model.now)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 660)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("工作时间统计")
                    .font(.system(size: 17, weight: .semibold))

                Spacer()

                Picker("", selection: $range) {
                    ForEach(StatsRange.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            HStack(spacing: 10) {
                metric(
                    "实际总工时",
                    TimeFormat.duration(Double(summary.workedMinutes))
                )
                metric(
                    "平均每日",
                    TimeFormat.duration(Double(summary.averageWorkedMinutes))
                )
                metric(
                    "加班总计",
                    TimeFormat.duration(Double(summary.overtimeMinutes)),
                    tint: summary.overtimeMinutes > 0 ? Theme.overtime : .primary
                )
                metric(
                    "记录天数",
                    "\(summary.days) 天",
                    detail: "\(summary.daysFromLock) 天来自锁屏"
                )
            }
        }
        .padding(20)
    }

    private func metric(
        _ title: String,
        _ value: String,
        tint: Color = .primary,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: Body

    /// Offscreen rendering has no viewport, so a ScrollView would lay out to
    /// nothing. Preview mode renders the rows directly instead.
    private var content: some View {
        Group {
            if preview {
                listBody
            } else {
                ScrollView { listBody }
            }
        }
    }

    private var listBody: some View {
        VStack(spacing: 0) {
            todayBanner
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, rows.isEmpty ? 0 : 8)

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
                rowView(record)
                if index < rows.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }

            if rows.isEmpty {
                emptyState
            }
        }
    }

    /// Today is still open, so it never appears in the settled list. Showing it
    /// here keeps the number the user came for visible.
    @ViewBuilder
    private var todayBanner: some View {
        let snap = model.snapshot
        if snap.isWorkday {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.statusColor(snap.phase))
                    .frame(width: 6, height: 6)

                Text("今天 · \(snap.phase.title)")
                    .font(.system(size: 11, weight: .semibold))

                Text("已工作 \(TimeFormat.duration(snap.elapsedWork))")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()

                if let minute = log.todayLockMinute(now: model.now) {
                    Text("最近锁屏 \(TimeFormat.minutes(minute % (24 * 60)))")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)

            Text("还没有记录")
                .font(.system(size: 13, weight: .semibold))

            Text("每天上班时间开始时，会把前一天最后一次锁屏时间记作下班时间。\n没有观测到锁屏的日子，会按排班时间结算。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 32)
    }

    // MARK: Row

    private func rowView(_ record: WorkDayRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dayLabel(record.dateKey))
                    .font(.system(size: 12, weight: .semibold))

                Text("\(TimeFormat.minutes(record.workStart)) → \(clockOutLabel(record.clockOut))")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 120, alignment: .leading)

            bar(record)
                .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 2) {
                Text(TimeFormat.duration(Double(record.workedMinutes)))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Text(deltaLabel(record))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(record.overtimeMinutes > 0 ? Theme.overtime : .secondary)
            }
            .frame(width: 92, alignment: .trailing)

            Text(record.source.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(record.source == .screenLock ? Theme.accent : .secondary)
                .frame(width: 28, alignment: .trailing)
                .help(record.source == .screenLock
                      ? "下班时间来自当天最后一次锁屏"
                      : "没有观测到锁屏，按排班下班时间结算")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// Bar scaled so the scheduled length is the reference; anything beyond it
    /// is drawn as overtime rather than overflowing.
    private func bar(_ record: WorkDayRecord) -> some View {
        let ratio = record.scheduledMinutes > 0
            ? Double(record.workedMinutes) / Double(record.scheduledMinutes)
            : 0
        let total = max(ratio, 1)
        let base = min(ratio, 1) / total
        let extra = max(0, ratio - 1) / total

        return GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                HStack(spacing: 0) {
                    Capsule()
                        .fill(Theme.accent.opacity(0.85))
                        .frame(width: max(0, width * base))

                    if extra > 0 {
                        Capsule()
                            .fill(Theme.overtime)
                            .frame(width: max(0, width * extra))
                            .padding(.leading, 1)
                    }
                }
            }
        }
        .frame(height: 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(log.logFileURL.path)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()

            if let error = log.lastError {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Button("显示") {
                NSWorkspace.shared.activateFileViewerSelecting([log.logFileURL])
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Labels

    private func dayLabel(_ key: String) -> String {
        guard let date = DayKey.date(from: key) else { return key }

        let calendar = Calendar.current
        let comps = calendar.dateComponents([.month, .day, .weekday], from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = ((comps.weekday ?? 1) - 1).clamped(to: 0...6)

        return String(
            format: "%02d-%02d %@",
            comps.month ?? 0,
            comps.day ?? 0,
            names[index]
        )
    }

    private func clockOutLabel(_ minute: Int) -> String {
        if minute >= 24 * 60 {
            return "次日 \(TimeFormat.minutes(minute - 24 * 60))"
        }
        return TimeFormat.minutes(minute)
    }

    private func deltaLabel(_ record: WorkDayRecord) -> String {
        if record.overtimeMinutes > 0 {
            return "+\(TimeFormat.duration(Double(record.overtimeMinutes)))"
        }
        if record.shortMinutes > 0 {
            return "−\(TimeFormat.duration(Double(record.shortMinutes)))"
        }
        return "准点"
    }
}
