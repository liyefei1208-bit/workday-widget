import Foundation
import Combine

// MARK: - Settings

struct WorkdaySettings: Codable, Equatable {
    var workStart: Int = 9 * 60 + 30      // 09:30
    var workEnd: Int = 19 * 60 + 30       // 19:30
    var lunchEnabled: Bool = true
    var lunchStart: Int = 12 * 60         // 12:00
    var lunchEnd: Int = 13 * 60           // 13:00
    var dinnerEnabled: Bool = true
    var dinnerStart: Int = 18 * 60        // 18:00
    var dinnerEnd: Int = 19 * 60          // 19:00

    var showDesktopWidget: Bool = true
    var showIsland: Bool = true

    var isValid: Bool {
        guard workEnd > workStart else { return false }
        if lunchEnabled {
            if lunchEnd <= lunchStart { return false }
            if lunchStart < workStart || lunchEnd > workEnd { return false }
        }
        if dinnerEnabled {
            if dinnerEnd <= dinnerStart { return false }
            if dinnerStart < workStart || dinnerEnd > workEnd { return false }
        }
        return true
    }

    static let `default` = WorkdaySettings()
}

// MARK: - Small helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

struct MinuteRange: Equatable {
    var start: Int
    var end: Int

    var length: Int { max(0, end - start) }

    /// Remaining minutes in this range at a given minute-of-day.
    func remaining(at minute: Double) -> Double {
        if minute <= Double(start) { return Double(length) }
        if minute >= Double(end) { return 0 }
        return Double(end) - minute
    }
}

// MARK: - Schedule

/// Work intervals with breaks subtracted, and the morning / afternoon split.
struct Schedule {
    let workStart: Int
    let workEnd: Int
    let lunchStart: Int
    let lunchEnd: Int
    let dinnerStart: Int
    let dinnerEnd: Int
    let lunchEnabled: Bool
    let dinnerEnabled: Bool

    init(settings: WorkdaySettings) {
        let dayRange = 0...(24 * 60)
        var start = settings.workStart.clamped(to: dayRange)
        var end = settings.workEnd.clamped(to: dayRange)
        if end < start { swap(&start, &end) }

        workStart = start
        workEnd = end
        lunchStart = settings.lunchStart.clamped(to: dayRange)
        lunchEnd = settings.lunchEnd.clamped(to: dayRange)
        dinnerStart = settings.dinnerStart.clamped(to: dayRange)
        dinnerEnd = settings.dinnerEnd.clamped(to: dayRange)
        lunchEnabled = settings.lunchEnabled
        dinnerEnabled = settings.dinnerEnabled
    }

    private var workRange: MinuteRange {
        MinuteRange(start: workStart, end: workEnd)
    }

    private var breaks: [MinuteRange] {
        var result: [MinuteRange] = []
        if lunchEnabled, lunchEnd > lunchStart {
            result.append(MinuteRange(start: lunchStart, end: lunchEnd))
        }
        if dinnerEnabled, dinnerEnd > dinnerStart {
            result.append(MinuteRange(start: dinnerStart, end: dinnerEnd))
        }
        return result.sorted { $0.start < $1.start }
    }

    /// All working ranges after subtracting breaks from the work window.
    var workRanges: [MinuteRange] {
        var ranges = [workRange]
        for brk in breaks {
            ranges = ranges.flatMap { subtract(brk, from: $0) }
        }
        return ranges
    }

    private func subtract(_ cut: MinuteRange, from range: MinuteRange) -> [MinuteRange] {
        if cut.end <= range.start || cut.start >= range.end { return [range] }
        var result: [MinuteRange] = []
        if cut.start > range.start {
            result.append(MinuteRange(start: range.start, end: min(cut.start, range.end)))
        }
        if cut.end < range.end {
            result.append(MinuteRange(start: max(cut.end, range.start), end: range.end))
        }
        return result
    }

    /// Morning / afternoon divider. Lunch start when lunch is enabled, otherwise noon.
    var midday: Int {
        if lunchEnabled, lunchEnd > lunchStart {
            return lunchStart.clamped(to: workStart...workEnd)
        }
        return (12 * 60).clamped(to: workStart...workEnd)
    }

    var morningRanges: [MinuteRange] {
        workRanges.compactMap { range in
            let start = max(range.start, workStart)
            let end = min(range.end, midday)
            return end > start ? MinuteRange(start: start, end: end) : nil
        }
    }

    var afternoonRanges: [MinuteRange] {
        workRanges.compactMap { range in
            let start = max(range.start, midday)
            let end = min(range.end, workEnd)
            return end > start ? MinuteRange(start: start, end: end) : nil
        }
    }

    var morningTotal: Double { Double(morningRanges.reduce(0) { $0 + $1.length }) }
    var afternoonTotal: Double { Double(afternoonRanges.reduce(0) { $0 + $1.length }) }
    var totalWork: Double { morningTotal + afternoonTotal }

    var morningRangeLabel: String {
        let raw = (lunchEnabled && lunchEnd > lunchStart) ? lunchStart : midday
        let end = max(workStart, min(raw, workEnd))
        return "\(TimeFormat.minutes(workStart))–\(TimeFormat.minutes(end))"
    }

    var afternoonRangeLabel: String {
        let raw = (lunchEnabled && lunchEnd > lunchStart) ? lunchEnd : midday
        let start = max(workStart, min(raw, workEnd))
        return "\(TimeFormat.minutes(start))–\(TimeFormat.minutes(workEnd))"
    }

    func remainingWork(at minute: Double) -> Double {
        workRanges.reduce(0) { $0 + $1.remaining(at: minute) }
    }

    func remainingMorning(at minute: Double) -> Double {
        morningRanges.reduce(0) { $0 + $1.remaining(at: minute) }
    }

    func remainingAfternoon(at minute: Double) -> Double {
        afternoonRanges.reduce(0) { $0 + $1.remaining(at: minute) }
    }
}

// MARK: - Day phase / snapshot

enum DayPhase: Equatable {
    case weekend
    case beforeWork
    case working
    case lunchBreak
    case dinnerBreak
    case afterWork
    case overtime

    var title: String {
        switch self {
        case .weekend: return "休息日"
        case .beforeWork: return "未开始"
        case .working: return "工作中"
        case .lunchBreak: return "午休中"
        case .dinnerBreak: return "休息中"
        case .afterWork: return "已下班"
        case .overtime: return "加班中"
        }
    }
}

struct DaySnapshot {
    let now: Date
    let settings: WorkdaySettings
    let schedule: Schedule
    let isWorkday: Bool
    let nowMinute: Double
    let phase: DayPhase

    let remainingWork: Double
    let remainingMorning: Double
    let remainingAfternoon: Double

    init(now: Date, settings: WorkdaySettings, calendar: Calendar = .current) {
        self.now = now
        self.settings = settings

        let schedule = Schedule(settings: settings)
        self.schedule = schedule

        let weekday = calendar.component(.weekday, from: now) // Sunday == 1
        let isWorkday = (2...6).contains(weekday)
        self.isWorkday = isWorkday

        let comps = calendar.dateComponents([.hour, .minute, .second], from: now)
        let minute = Double(comps.hour ?? 0) * 60
            + Double(comps.minute ?? 0)
            + Double(comps.second ?? 0) / 60
        self.nowMinute = minute

        if !isWorkday {
            phase = .weekend
        } else if minute < Double(schedule.workStart) {
            phase = .beforeWork
        } else if minute >= Double(schedule.workEnd) {
            phase = minute > Double(schedule.workEnd) ? .overtime : .afterWork
        } else if settings.lunchEnabled,
                  schedule.lunchEnd > schedule.lunchStart,
                  minute >= Double(schedule.lunchStart),
                  minute < Double(schedule.lunchEnd) {
            phase = .lunchBreak
        } else if settings.dinnerEnabled,
                  schedule.dinnerEnd > schedule.dinnerStart,
                  minute >= Double(schedule.dinnerStart),
                  minute < Double(schedule.dinnerEnd) {
            phase = .dinnerBreak
        } else {
            phase = .working
        }

        if isWorkday {
            remainingWork = schedule.remainingWork(at: minute)
            remainingMorning = schedule.remainingMorning(at: minute)
            remainingAfternoon = schedule.remainingAfternoon(at: minute)
        } else {
            remainingWork = 0
            remainingMorning = 0
            remainingAfternoon = 0
        }
    }

    var totalWork: Double { schedule.totalWork }
    var morningTotal: Double { schedule.morningTotal }
    var afternoonTotal: Double { schedule.afternoonTotal }

    /// Completed share (0...1). The whole widget uses "completed" semantics.
    var overallProgress: Double {
        guard isWorkday, totalWork > 0 else { return 0 }
        return ((totalWork - remainingWork) / totalWork).clamped(to: 0...1)
    }

    var morningProgress: Double {
        guard isWorkday, morningTotal > 0 else { return 0 }
        return ((morningTotal - remainingMorning) / morningTotal).clamped(to: 0...1)
    }

    var afternoonProgress: Double {
        guard isWorkday, afternoonTotal > 0 else { return 0 }
        return ((afternoonTotal - remainingAfternoon) / afternoonTotal).clamped(to: 0...1)
    }

    var percentOverall: Int { Int((overallProgress * 100).rounded()) }
    var percentMorning: Int { Int((morningProgress * 100).rounded()) }
    var percentAfternoon: Int { Int((afternoonProgress * 100).rounded()) }

    var elapsedWork: Double {
        isWorkday ? max(0, totalWork - remainingWork) : 0
    }

    var minutesUntilWorkStart: Double {
        max(0, Double(schedule.workStart) - nowMinute)
    }

    /// Wall-clock minutes past the end of the workday. Resets when the date
    /// rolls over at midnight (the snapshot is always built for "today").
    var overtimeMinutes: Double {
        guard isWorkday, phase == .overtime else { return 0 }
        return max(0, nowMinute - Double(schedule.workEnd))
    }

    var morningRangeLabel: String { schedule.morningRangeLabel }
    var afternoonRangeLabel: String { schedule.afternoonRangeLabel }
}

// MARK: - Formatting

enum TimeFormat {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// 570 -> "9:30"
    static func minutes(_ value: Int) -> String {
        let clamped = value.clamped(to: 0...(24 * 60))
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// "9:30 – 19:30"
    static func range(_ start: Int, _ end: Int) -> String {
        "\(minutes(start)) – \(minutes(end))"
    }

    /// Remaining work duration, e.g. "2 小时 18 分".
    static func duration(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded(.up)))
        if total == 0 { return "0 分钟" }
        let hours = total / 60
        let mins = total % 60
        if hours > 0, mins > 0 { return "\(hours) 小时 \(mins) 分" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(mins) 分钟"
    }

    /// Date helpers used by the settings DatePickers.
    static func date(minutes: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let clamped = minutes.clamped(to: 0...(24 * 60 - 1))
        comps.hour = clamped / 60
        comps.minute = clamped % 60
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    static func minutes(from date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    static func nextWorkdayLabel(from now: Date, workStart: Int) -> String {
        let calendar = Calendar.current
        var date = now
        for _ in 0..<8 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
            let weekday = calendar.component(.weekday, from: date)
            if (2...6).contains(weekday) {
                let index = (weekday - 1).clamped(to: 0...6)
                return "\(weekdayNames[index]) \(minutes(workStart))"
            }
        }
        return "周一 \(minutes(workStart))"
    }
}

// MARK: - Model

final class WorkdayModel: ObservableObject {
    @Published var settings: WorkdaySettings {
        didSet { persist() }
    }

    @Published var now: Date = Date()

    private static let storageKey = "workday.settings.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(WorkdaySettings.self, from: data) {
            settings = decoded
        } else {
            settings = WorkdaySettings()
        }
    }

    var snapshot: DaySnapshot {
        DaySnapshot(now: now, settings: settings)
    }

    func reset() {
        settings = WorkdaySettings()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
