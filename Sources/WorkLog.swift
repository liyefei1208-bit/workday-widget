import AppKit
import Combine
import Foundation

// MARK: - Record

/// Where a day's clock-out time came from.
enum ClockOutSource: String, Codable {
    /// The last screen-lock event observed on that day.
    case screenLock
    /// Nothing was observed, so the scheduled end of the workday was used.
    case scheduled

    var label: String {
        switch self {
        case .screenLock: return "锁屏"
        case .scheduled: return "排班"
        }
    }
}

/// One finished workday.
struct WorkDayRecord: Codable, Identifiable, Equatable {
    /// `yyyy-MM-dd` in the local time zone.
    var dateKey: String
    var workStart: Int
    var scheduledEnd: Int
    /// Minutes past midnight of `dateKey`. Exceeds 1440 when the day was closed
    /// after midnight.
    var clockOut: Int
    var source: ClockOutSource
    var workedMinutes: Int
    var scheduledMinutes: Int
    var recordedAt: Date

    var id: String { dateKey }

    var overtimeMinutes: Int { max(0, workedMinutes - scheduledMinutes) }
    var shortMinutes: Int { max(0, scheduledMinutes - workedMinutes) }
}

// MARK: - Day keys

enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func make(_ date: Date) -> String { formatter.string(from: date) }

    static func date(from key: String) -> Date? { formatter.date(from: key) }
}

// MARK: - Maths

/// Pure helpers, kept separate from storage so they can be exercised without a
/// file or a running app (see `--log-selftest`).
enum WorkLogMath {
    /// Locks before this minute-of-day are treated as the previous day's
    /// clock-out, so working past midnight still closes the right day.
    static let midnightRolloverLimit = 6 * 60

    /// Actual worked minutes from the start of the workday to `clockOut`,
    /// with breaks excluded and anything past the scheduled end counted as
    /// overtime.
    static func workedMinutes(schedule: Schedule, clockOut: Int) -> Int {
        let minute = Double(clockOut)
        let scheduled = schedule.totalWork - schedule.remainingWork(at: minute)
        let overtime = max(0, minute - Double(schedule.workEnd))
        return Int((scheduled + overtime).rounded())
    }

    /// Which day a lock event closes, and the minute-of-day to record.
    static func attribution(
        for lockDate: Date,
        calendar: Calendar = .current
    ) -> (key: String, minute: Int) {
        let minute = TimeFormat.minutes(from: lockDate)
        if minute < midnightRolloverLimit,
           let previous = calendar.date(byAdding: .day, value: -1, to: lockDate) {
            return (DayKey.make(previous), minute + 24 * 60)
        }
        return (DayKey.make(lockDate), minute)
    }

    static func isWorkday(_ date: Date, calendar: Calendar = .current) -> Bool {
        (2...6).contains(calendar.component(.weekday, from: date))
    }
}

// MARK: - Summary

struct WorkLogSummary {
    var days: Int = 0
    var workedMinutes: Int = 0
    var scheduledMinutes: Int = 0
    var overtimeMinutes: Int = 0
    var shortMinutes: Int = 0
    var daysFromLock: Int = 0

    var averageWorkedMinutes: Int {
        days == 0 ? 0 : workedMinutes / days
    }
}

enum StatsRange: String, CaseIterable, Identifiable {
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "本周"
        case .month: return "本月"
        case .all: return "全部"
        }
    }

    func contains(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
            return date >= start
        case .month:
            let start = calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
            return date >= start
        }
    }
}

// MARK: - Log

/// Records the actual length of each workday.
///
/// The clock-out time is the last screen lock observed on that day. macOS
/// exposes no API for lock history, so only locks that happen while this app is
/// running can be seen — which it always is, since it is a menu bar agent.
/// `com.apple.screenIsLocked` is an undocumented notification, but it has been
/// stable for many releases and is what every lock-aware utility on macOS uses.
///
/// A day with no observed lock is closed at its scheduled end and marked
/// `scheduled`, so the statistics never invent an end time silently.
final class WorkLog: ObservableObject {
    @Published private(set) var records: [WorkDayRecord] = []
    @Published private(set) var lastError: String?

    /// dateKey -> latest lock minute-of-day seen for that day.
    private(set) var pendingLock: [String: Int] = [:]

    /// First day this log ever saw. Nothing before it is settled, because the
    /// app could not have observed those days' lock events.
    private(set) var firstDayKey: String = DayKey.make(Date())

    private let fileURL: URL
    private var observers: [NSObjectProtocol] = []

    private static let payloadVersion = 1
    private static let retentionDays = 60
    private static let maxRecords = 800

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())

        return base
            .appendingPathComponent("Workday", isDirectory: true)
            .appendingPathComponent("worklog.json")
    }

    init(fileURL: URL = WorkLog.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Observation

    func startObserving(settings: @escaping () -> WorkdaySettings) {
        let distributed = DistributedNotificationCenter.default()
        let lockName = Notification.Name("com.apple.screenIsLocked")

        observers.append(
            distributed.addObserver(forName: lockName, object: nil, queue: .main) { [weak self] _ in
                self?.handleLock(at: Date(), settings: settings())
            }
        )

        // Catching up after sleep matters: a machine that was asleep at the
        // scheduled start would otherwise skip that day's settlement.
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.reconcile(now: Date(), settings: settings())
            }
        )
    }

    func stopObserving() {
        let distributed = DistributedNotificationCenter.default()
        observers.forEach(distributed.removeObserver)
        observers
            .forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    // MARK: Ingest

    /// Records a lock event. Called from the distributed notification above.
    func handleLock(at date: Date, settings: WorkdaySettings) {
        let (key, minute) = WorkLogMath.attribution(for: date)
        guard let day = DayKey.date(from: key), WorkLogMath.isWorkday(day) else { return }

        // Keep the latest lock of the day; earlier ones are irrelevant.
        if let existing = pendingLock[key], existing >= minute { return }

        pendingLock[key] = minute
        save()
    }

    // MARK: Settlement

    /// Closes every workday that is due and not yet recorded.
    ///
    /// A day becomes due at the start of the next workday — that is the
    /// "每天早上上班时间开始时" settlement point.
    func reconcile(now: Date = Date(), settings: WorkdaySettings) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return }

        let schedule = Schedule(settings: settings)

        // Never settle a day the log did not exist for: those would be invented
        // records with no observation behind them.
        let firstDay = calendar.startOfDay(
            for: DayKey.date(from: firstDayKey) ?? now
        )

        let newest = records.compactMap { DayKey.date(from: $0.dateKey) }.max()
        var cursor: Date
        if let newest {
            cursor = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: newest))
                ?? today
        } else {
            cursor = firstDay
        }
        if cursor < firstDay { cursor = firstDay }

        var changed = false
        while cursor <= yesterday {
            let next = calendar.date(byAdding: .day, value: 1, to: cursor)

            defer {
                if let next { cursor = next }
            }

            guard let next, WorkLogMath.isWorkday(cursor, calendar: calendar) else { continue }
            if records.contains(where: { $0.dateKey == DayKey.make(cursor) }) { continue }

            // Settle only once the following workday has started.
            var comps = calendar.dateComponents([.year, .month, .day], from: next)
            comps.hour = settings.workStart / 60
            comps.minute = settings.workStart % 60
            comps.second = 0
            guard let due = calendar.date(from: comps), now >= due else { continue }

            let key = DayKey.make(cursor)
            records.append(makeRecord(key: key, schedule: schedule, settings: settings))
            changed = true
        }

        prunePending(now: today, calendar: calendar)

        if changed {
            sortRecords()
            save()
        }
    }

    private func makeRecord(
        key: String,
        schedule: Schedule,
        settings: WorkdaySettings
    ) -> WorkDayRecord {
        let lock = pendingLock[key]

        let clockOut: Int
        let source: ClockOutSource
        if let lock, lock > settings.workStart {
            clockOut = lock
            source = .screenLock
        } else {
            clockOut = settings.workEnd
            source = .scheduled
        }

        return WorkDayRecord(
            dateKey: key,
            workStart: settings.workStart,
            scheduledEnd: settings.workEnd,
            clockOut: clockOut,
            source: source,
            workedMinutes: WorkLogMath.workedMinutes(schedule: schedule, clockOut: clockOut),
            scheduledMinutes: Int(schedule.totalWork.rounded()),
            recordedAt: Date()
        )
    }

    private func prunePending(now: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -7, to: now) else { return }
        pendingLock = pendingLock.filter { key, _ in
            guard let day = DayKey.date(from: key) else { return false }
            return day >= cutoff
        }
    }

    // MARK: Queries

    func records(in range: StatsRange, now: Date = Date()) -> [WorkDayRecord] {
        records.filter { record in
            guard let date = DayKey.date(from: record.dateKey) else { return false }
            return range.contains(date, now: now)
        }
    }

    func summary(in range: StatsRange, now: Date = Date()) -> WorkLogSummary {
        var summary = WorkLogSummary()
        for record in records(in: range, now: now) {
            summary.days += 1
            summary.workedMinutes += record.workedMinutes
            summary.scheduledMinutes += record.scheduledMinutes
            summary.overtimeMinutes += record.overtimeMinutes
            summary.shortMinutes += record.shortMinutes
            if record.source == .screenLock { summary.daysFromLock += 1 }
        }
        return summary
    }

    /// The latest lock seen for today, if any — used to show progress before
    /// the day is settled.
    func todayLockMinute(now: Date = Date()) -> Int? {
        pendingLock[DayKey.make(now)]
    }

    // MARK: Persistence

    private struct Payload: Codable {
        var version: Int
        var records: [WorkDayRecord]
        var pendingLock: [String: Int]
        var firstDayKey: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // First run: the log starts today, so no earlier day is settled.
            save()
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            lastError = "无法解析 \(fileURL.lastPathComponent)，已忽略旧数据。"
            return
        }

        records = payload.records
        pendingLock = payload.pendingLock
        if let first = payload.firstDayKey {
            firstDayKey = first
        }
        sortRecords()
    }

    func save() {
        let payload = Payload(
            version: Self.payloadVersion,
            records: Array(records.prefix(Self.maxRecords)),
            pendingLock: pendingLock,
            firstDayKey: firstDayKey
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(payload) else {
            lastError = "记录编码失败。"
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "写入失败：\(error.localizedDescription)"
        }
    }

    private func sortRecords() {
        records.sort { $0.dateKey > $1.dateKey }
    }

    var logFileURL: URL { fileURL }

    /// Replaces the in-memory log and rewrites the file. Used by the self-test.
    func replaceAll(
        records: [WorkDayRecord],
        pendingLock: [String: Int] = [:],
        firstDayKey: String? = nil
    ) {
        self.records = records
        self.pendingLock = pendingLock
        if let firstDayKey { self.firstDayKey = firstDayKey }
        sortRecords()
        save()
    }
}
