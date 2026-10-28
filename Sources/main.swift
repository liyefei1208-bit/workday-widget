import AppKit
import SwiftUI

// MARK: - CLI helpers (used for previews and logic checks)

private func flagValue(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

private func dateAt(_ hhmm: String) -> Date? {
    let parts = hhmm.split(separator: ":")
    guard parts.count >= 2,
          let hour = Int(parts[0]),
          let minute = Int(parts[1]) else { return nil }

    var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    comps.hour = hour
    comps.minute = minute
    comps.second = 0
    return Calendar.current.date(from: comps)
}

private func nextSaturday(from date: Date) -> Date {
    let calendar = Calendar.current
    var current = date
    for _ in 0..<8 {
        guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
        current = next
        if calendar.component(.weekday, from: current) == 7 { // Saturday
            var comps = calendar.dateComponents([.year, .month, .day], from: current)
            comps.hour = 10
            comps.minute = 30
            comps.second = 0
            return calendar.date(from: comps) ?? current
        }
    }
    return current
}

@MainActor
private func writePNG(_ renderer: ImageRenderer<some View>, to path: String) -> Bool {
    guard let cgImage = renderer.cgImage else {
        FileHandle.standardError.write(Data("Failed to render image.\n".utf8))
        return false
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("Failed to encode PNG.\n".utf8))
        return false
    }

    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
        return true
    } catch {
        FileHandle.standardError.write(Data("Failed to write \(path): \(error)\n".utf8))
        return false
    }
}

@MainActor
private func renderIcon(path: String) {
    let renderer = ImageRenderer(content: AppIconView())
    renderer.scale = 1
    _ = writePNG(renderer, to: path)
}

@MainActor
private func renderPreview(
    path: String,
    at date: Date,
    island: Bool,
    compact: Bool,
    scheme: ColorScheme,
    reminder: ReminderKind? = nil
) {
    let model = WorkdayModel()
    model.now = date

    let content: AnyView
    if island {
        let state = IslandState()
        if let reminder {
            // A reminder always expands; --compact would contradict it.
            state.showReminder(Reminder.sample(for: reminder))
        } else if !compact {
            state.setHovering(true)
        }
        let metrics = CommandLine.arguments.contains("--no-notch")
            ? IslandMetrics(hasNotch: false, notchWidth: 190, notchHeight: 32)
            : IslandMetrics.previewNotch
        content = AnyView(
            IslandRoot(model: model, state: state, metrics: metrics, preview: true)
                .environment(\.colorScheme, .dark)
        )
    } else {
        content = AnyView(
            WidgetWindowRoot(model: model, preview: true)
                .environment(\.colorScheme, scheme)
        )
    }

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
    _ = writePNG(renderer, to: path)
}

// MARK: - Work-log self test

private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    var comps = DateComponents()
    comps.year = year
    comps.month = month
    comps.day = day
    comps.hour = hour
    comps.minute = minute
    comps.second = 0
    return Calendar.current.date(from: comps) ?? Date()
}

/// Exercises the settlement rules without needing to wait for a real workday to
/// end. Exits non-zero on failure so it can gate a build.
private func runLogSelfTest() -> Int32 {
    var failures = 0

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("  ok   \(name)")
        } else {
            let extra = detail()
            print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
            failures += 1
        }
    }

    let settings = WorkdaySettings.default
    let schedule = Schedule(settings: settings)

    print("== 实际工时 ==")
    let workCases: [(String, Int, Int)] = [
        ("09:30 上班时刻", 9 * 60 + 30, 0),
        ("11:00 上午", 11 * 60, 90),
        ("13:00 午休结束", 13 * 60, 150),
        ("19:00 晚餐结束", 19 * 60, 450),
        ("19:30 下班", 19 * 60 + 30, 480),
        ("20:12 加班", 20 * 60 + 12, 522),
        ("次日 01:00", 25 * 60, 810),
    ]
    for (label, clockOut, expected) in workCases {
        let actual = WorkLogMath.workedMinutes(schedule: schedule, clockOut: clockOut)
        check(label, actual == expected, "期望 \(expected)，实际 \(actual)")
    }

    print("== 锁屏归属 ==")
    let evening = WorkLogMath.attribution(for: makeDate(2026, 10, 27, 20, 12))
    check(
        "20:12 归当天",
        evening.key == "2026-10-27" && evening.minute == 1212,
        "\(evening.key) \(evening.minute)"
    )

    let afterMidnight = WorkLogMath.attribution(for: makeDate(2026, 10, 28, 1, 0))
    check(
        "凌晨 01:00 归前一天",
        afterMidnight.key == "2026-10-27" && afterMidnight.minute == 1500,
        "\(afterMidnight.key) \(afterMidnight.minute)"
    )

    let morning = WorkLogMath.attribution(for: makeDate(2026, 10, 28, 9, 0))
    check(
        "早上 09:00 归当天",
        morning.key == "2026-10-28" && morning.minute == 540,
        "\(morning.key) \(morning.minute)"
    )

    print("== 结算 ==")
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklog-selftest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: temp) }

    // 2026-10-26 is Monday, 10-27 Tuesday, 10-28 Wednesday.
    let log = WorkLog(fileURL: temp)
    log.replaceAll(
        records: [],
        pendingLock: ["2026-10-27": 21 * 60],
        firstDayKey: "2026-10-26"
    )
    log.reconcile(now: makeDate(2026, 10, 28, 9, 30), settings: settings)

    let tuesday = log.records.first { $0.dateKey == "2026-10-27" }
    check("10-27 已结算", tuesday != nil)
    check("10-27 下班取锁屏 21:00", tuesday?.clockOut == 1260, "\(tuesday?.clockOut ?? -1)")
    check("10-27 来源锁屏", tuesday?.source == .screenLock, "\(tuesday?.source.rawValue ?? "nil")")
    check("10-27 实际 9h30m", tuesday?.workedMinutes == 570, "\(tuesday?.workedMinutes ?? -1)")

    let monday = log.records.first { $0.dateKey == "2026-10-26" }
    check("10-26 无锁屏回退排班", monday?.clockOut == 1170, "\(monday?.clockOut ?? -1)")
    check("10-26 来源排班", monday?.source == .scheduled, "\(monday?.source.rawValue ?? "nil")")
    check("10-26 实际 8h", monday?.workedMinutes == 480, "\(monday?.workedMinutes ?? -1)")

    check("10-28 当天尚未结算", log.records.first { $0.dateKey == "2026-10-28" } == nil)
    check("10-23 未被编造", log.records.first { $0.dateKey == "2026-10-23" } == nil)

    let countAfterFirst = log.records.count
    log.reconcile(now: makeDate(2026, 10, 28, 9, 31), settings: settings)
    check("重复结算不产生重复记录", log.records.count == countAfterFirst,
          "\(countAfterFirst) -> \(log.records.count)")

    check("已写入文件", FileManager.default.fileExists(atPath: temp.path))

    let reloaded = WorkLog(fileURL: temp)
    check("重载后记录数一致", reloaded.records.count == log.records.count,
          "\(reloaded.records.count) vs \(log.records.count)")
    check("重载后保留首次运行日", reloaded.firstDayKey == "2026-10-26", reloaded.firstDayKey)

    print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
    return failures == 0 ? 0 : 1
}

// MARK: - Reminder self test

/// Exercises the firing rules. Uses an isolated defaults suite so the real
/// reminder settings are untouched.
private func runReminderSelfTest() -> Int32 {
    var failures = 0

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok {
            print("  ok   \(name)")
        } else {
            let extra = detail()
            print("  FAIL \(name)\(extra.isEmpty ? "" : " — \(extra)")")
            failures += 1
        }
    }

    let settings = WorkdaySettings.default
    let lunch = Reminder.defaults[0]

    print("== 时间解析 ==")
    check("午休跟随排班 12:00", lunch.effectiveTime(settings) == 12 * 60,
          "\(lunch.effectiveTime(settings) ?? -1)")

    var pinned = Reminder(kind: .lunch, time: 13 * 60 + 30, title: "t", message: "")
    check("显式时间覆盖排班", pinned.effectiveTime(settings) == 13 * 60 + 30)
    pinned.time = nil
    check("清除后回到排班", pinned.effectiveTime(settings) == 12 * 60)

    var noLunch = settings
    noLunch.lunchEnabled = false
    check("关闭午休后无提醒时间", lunch.effectiveTime(noLunch) == nil)

    check("自定义提醒无时间不触发",
          Reminder(kind: .custom, title: "t", message: "").effectiveTime(settings) == nil)

    print("== 触发规则 ==")
    let suite = "workday.reminders.selftest"
    UserDefaults().removePersistentDomain(forName: suite)
    let defaults = UserDefaults(suiteName: suite)!

    let center = ReminderCenter(defaults: defaults, storageKey: "selftest")
    var fired: [ReminderKind] = []
    center.onFire = { fired.append($0.kind) }

    // 2026-10-28 is a Wednesday.
    center.evaluate(now: makeDate(2026, 10, 28, 11, 59), settings: settings)
    check("11:59 不触发", fired.isEmpty, "\(fired)")

    center.evaluate(now: makeDate(2026, 10, 28, 12, 0), settings: settings)
    check("12:00 触发午休", fired == [.lunch], "\(fired)")

    center.evaluate(now: makeDate(2026, 10, 28, 12, 0), settings: settings)
    check("同一分钟只触发一次", fired == [.lunch], "\(fired)")

    center.evaluate(now: makeDate(2026, 10, 28, 18, 0), settings: settings)
    check("18:00 触发晚餐", fired == [.lunch, .dinner], "\(fired)")

    center.evaluate(now: makeDate(2026, 10, 28, 19, 30), settings: settings)
    check("19:30 触发下班", fired == [.lunch, .dinner, .workEnd], "\(fired)")

    center.evaluate(now: makeDate(2026, 10, 29, 12, 0), settings: settings)
    check("次日重新触发", fired.count == 4, "\(fired)")

    let countBeforeWeekend = fired.count
    center.evaluate(now: makeDate(2026, 10, 31, 12, 0), settings: settings) // Saturday
    check("周末不触发", fired.count == countBeforeWeekend, "\(fired)")

    center.config.reminders[0].enabled = false
    fired.removeAll()
    center.evaluate(now: makeDate(2026, 11, 2, 12, 0), settings: settings) // Monday
    check("关闭的提醒不触发", !fired.contains(.lunch), "\(fired)")

    center.config.enabled = false
    fired.removeAll()
    center.evaluate(now: makeDate(2026, 11, 2, 18, 0), settings: settings)
    check("总开关关闭后全部不触发", fired.isEmpty, "\(fired)")

    print("== 持久化 ==")
    center.config.enabled = true
    fired.removeAll()
    center.evaluate(now: makeDate(2026, 11, 3, 18, 0), settings: settings)
    check("恢复后正常触发", fired == [.dinner], "\(fired)")

    let reloaded = ReminderCenter(defaults: defaults, storageKey: "selftest")
    check("触发记录已持久化", !reloaded.config.fired.isEmpty,
          "\(reloaded.config.fired.count)")

    reloaded.evaluate(now: makeDate(2026, 11, 3, 18, 0), settings: settings)
    check("重启后同一天不重复", fired == [.dinner], "\(fired)")

    UserDefaults().removePersistentDomain(forName: suite)

    print(failures == 0 ? "\n全部通过" : "\n\(failures) 项失败")
    return failures == 0 ? 0 : 1
}

// MARK: - Stats preview

@MainActor
private func renderStats(path: String) {
    let model = WorkdayModel()
    model.now = makeDate(2026, 10, 28, 15, 20)

    let settings = WorkdaySettings.default
    let schedule = Schedule(settings: settings)

    func record(_ key: String, _ clockOut: Int, _ source: ClockOutSource) -> WorkDayRecord {
        WorkDayRecord(
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

    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("worklog-preview-\(UUID().uuidString).json")
    let log = WorkLog(fileURL: temp)
    log.replaceAll(
        records: [
            record("2026-10-27", 19 * 60 + 45, .screenLock),
            record("2026-10-26", 20 * 60, .screenLock),
            record("2026-10-23", 19 * 60 + 30, .scheduled),
            record("2026-10-22", 18 * 60 + 15, .screenLock),
            record("2026-10-21", 21 * 60 + 30, .screenLock),
            record("2026-10-20", 19 * 60 + 30, .scheduled),
            record("2026-10-19", 20 * 60 + 25, .screenLock),
        ],
        pendingLock: ["2026-10-28": 14 * 60 + 5],
        firstDayKey: "2026-10-19"
    )

    let view = StatsView(model: model, log: log, initialRange: .month, preview: true)
        .environment(\.colorScheme, .light)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    _ = writePNG(renderer, to: path)
    try? FileManager.default.removeItem(at: temp)
}

// MARK: - Entry point

let args = CommandLine.arguments

if args.contains("--help") {
    print("""
    WorkdayWidget — 桌面工作日进度组件

    用法:
      WorkdayWidget                启动应用
      WorkdayWidget --dump [--at HH:mm] [--weekend]
                                   打印当前时间点的计算结果
      WorkdayWidget --render <png> [--at HH:mm] [--weekend] [--island] [--compact] [--light]
                                   渲染预览图后退出
      WorkdayWidget --log-selftest  校验工时记录的结算规则，失败时返回非 0
      WorkdayWidget --log-dump      打印已记录的工时
      WorkdayWidget --reminder-selftest
                                    校验提醒的触发规则，失败时返回非 0
    """)
    exit(0)
}

if args.contains("--reminder-selftest") {
    exit(runReminderSelfTest())
}

if args.contains("--log-selftest") {
    exit(runLogSelfTest())
}

if args.contains("--log-dump") {
    let log = WorkLog()
    print("file: \(log.logFileURL.path)")
    print("firstDay: \(log.firstDayKey)")
    print("pendingLock: \(log.pendingLock.sorted { $0.key < $1.key })")
    if log.records.isEmpty {
        print("no records")
    }
    for record in log.records {
        print(
            "\(record.dateKey)  \(TimeFormat.minutes(record.workStart))→\(TimeFormat.minutes(record.clockOut))"
            + "  \(record.source.label)  worked=\(record.workedMinutes)min"
            + "  scheduled=\(record.scheduledMinutes)min  overtime=\(record.overtimeMinutes)min"
        )
    }
    exit(0)
}

if args.contains("--dump") {
    var date = Date()
    if let at = flagValue("--at"), let parsed = dateAt(at) { date = parsed }
    if args.contains("--weekend") { date = nextSaturday(from: date) }

    let snap = DaySnapshot(now: date, settings: WorkdaySettings())
    print("time=\(TimeFormat.clock(date)) isWorkday=\(snap.isWorkday) phase=\(snap.phase)")
    print("completed=\(snap.percentOverall)% morning=\(snap.percentMorning)% afternoon=\(snap.percentAfternoon)%")
    print("elapsed=\(Int(snap.elapsedWork.rounded()))min remaining=\(Int(snap.remainingWork.rounded()))min overtime=\(Int(snap.overtimeMinutes.rounded()))min")
    print("total=\(Int(snap.totalWork))min morningTotal=\(Int(snap.morningTotal))min afternoonTotal=\(Int(snap.afternoonTotal))min")
    exit(0)
}

let application = NSApplication.shared

if args.contains("--dump-island") {
    for (index, screen) in NSScreen.screens.enumerated() {
        let m = IslandMetrics(screen: screen)
        let collapsed = IslandLayout.collapsedSize(m)
        let expanded = IslandLayout.expandedSize(m)
        let window = IslandLayout.windowSize(m)
        let centerX = screen.frame.midX + m.centerOffset

        print("screen[\(index)] frame=\(screen.frame)")
        print("  hasNotch=\(m.hasNotch) notch=\(m.notchWidth)x\(m.notchHeight) centerOffset=\(m.centerOffset)")
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            print("  realNotchRect=x \(l.maxX)…\(r.minX), y \(screen.frame.maxY - m.notchHeight)…\(screen.frame.maxY)")
        }
        print("  window=\(window.width)x\(window.height) origin=(\(centerX - window.width / 2), \(screen.frame.maxY - window.height))")
        print("  collapsedIsland=x \(centerX - collapsed.width / 2)…\(centerX + collapsed.width / 2), y \(screen.frame.maxY - collapsed.height)…\(screen.frame.maxY)")
        print("  expandedIsland=x \(centerX - expanded.width / 2)…\(centerX + expanded.width / 2), y \(screen.frame.maxY - expanded.height)…\(screen.frame.maxY)")
        print("  expandedBody=x \(centerX - (expanded.width - 2 * IslandLayout.flare) / 2)…\(centerX + (expanded.width - 2 * IslandLayout.flare) / 2)")
    }
    exit(0)
}

if let iconPath = flagValue("--render-icon") {
    MainActor.assumeIsolated {
        renderIcon(path: iconPath)
    }
    exit(0)
}

if let statsPath = flagValue("--render-stats") {
    MainActor.assumeIsolated {
        renderStats(path: statsPath)
    }
    exit(0)
}

if let renderPath = flagValue("--render") {
    var date = Date()
    if let at = flagValue("--at"), let parsed = dateAt(at) { date = parsed }
    if args.contains("--weekend") { date = nextSaturday(from: date) }

    MainActor.assumeIsolated {
        renderPreview(
            path: renderPath,
            at: date,
            island: args.contains("--island"),
            compact: args.contains("--compact"),
            scheme: args.contains("--light") ? .light : .dark,
            reminder: flagValue("--reminder").flatMap(ReminderKind.init(rawValue:))
        )
    }
    exit(0)
}

application.setActivationPolicy(.accessory)
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
