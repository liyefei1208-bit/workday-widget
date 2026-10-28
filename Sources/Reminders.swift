import Foundation
import SwiftUI

// MARK: - Kinds

enum ReminderKind: String, Codable, CaseIterable, Identifiable {
    case lunch
    case dinner
    case workEnd
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lunch: return "午休提醒"
        case .dinner: return "晚餐提醒"
        case .workEnd: return "下班提醒"
        case .custom: return "自定义提醒"
        }
    }

    var icon: String {
        switch self {
        case .lunch: return "fork.knife"
        case .dinner: return "moon.stars.fill"
        case .workEnd: return "house.fill"
        case .custom: return "bell.fill"
        }
    }

    var tint: Color {
        switch self {
        case .lunch: return Theme.ringMorning
        case .dinner: return Theme.rest
        case .workEnd: return Theme.accent
        case .custom: return Theme.ringAfternoon
        }
    }

    /// Built-in kinds default to a time taken from the schedule, so changing
    /// the work hours moves them unless the user pinned an explicit time.
    var followsScheduleByDefault: Bool { self != .custom }
}

// MARK: - Reminder

struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ReminderKind
    var enabled = true
    /// Explicit minute-of-day. `nil` follows the schedule.
    var time: Int?
    var title: String
    var message: String

    /// The minute this reminder actually fires at, or `nil` when there is no
    /// sensible time (a disabled lunch break, or a custom reminder with no time).
    func effectiveTime(_ settings: WorkdaySettings) -> Int? {
        if let time { return time }
        switch kind {
        case .lunch:
            return settings.lunchEnabled ? settings.lunchStart : nil
        case .dinner:
            return settings.dinnerEnabled ? settings.dinnerStart : nil
        case .workEnd:
            return settings.workEnd
        case .custom:
            return nil
        }
    }

    /// A representative instance of a kind, for previews and the debug flags.
    static func sample(for kind: ReminderKind) -> Reminder {
        defaults.first { $0.kind == kind }
            ?? Reminder(
                kind: kind,
                time: 15 * 60,
                title: "自定义提醒",
                message: "这是一条自定义提醒的内容"
            )
    }

    static let defaults: [Reminder] = [
        Reminder(
            kind: .lunch,
            title: "午休时间到",
            message: "去吃个饭，回来再继续"
        ),
        Reminder(
            kind: .dinner,
            title: "晚餐休息",
            message: "起来活动一下，吃点东西"
        ),
        Reminder(
            kind: .workEnd,
            title: "下班了",
            message: "今天辛苦了，早点休息"
        ),
    ]
}

// MARK: - Config

struct ReminderConfig: Codable, Equatable {
    var enabled = true
    var reminders: [Reminder] = Reminder.defaults
    /// reminder id -> dateKey it last fired on, so a restart does not repeat it.
    var fired: [String: String] = [:]
}

// MARK: - Center

/// Fires reminders at their configured minute and remembers which ones already
/// went off today.
final class ReminderCenter: ObservableObject {
    /// How long a reminder stays expanded before collapsing on its own. Without
    /// this a reminder nobody dismisses would cover the top of the screen until
    /// the next one arrives.
    static let autoDismissAfter: TimeInterval = 3

    @Published var config: ReminderConfig {
        didSet { persist() }
    }

    /// Called on the main thread when a reminder comes due.
    var onFire: ((Reminder) -> Void)?

    static let defaultStorageKey = "workday.reminders.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    /// The store is injectable so `--reminder-selftest` can exercise firing
    /// without touching the real settings.
    init(defaults: UserDefaults = .standard, storageKey: String = ReminderCenter.defaultStorageKey) {
        self.defaults = defaults
        self.storageKey = storageKey

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(ReminderConfig.self, from: data) {
            config = decoded
        } else {
            config = ReminderConfig()
        }
    }

    // MARK: Evaluation

    /// Called once a second; only the matching minute does anything.
    func evaluate(now: Date = Date(), settings: WorkdaySettings, calendar: Calendar = .current) {
        guard config.enabled else { return }
        guard (2...6).contains(calendar.component(.weekday, from: now)) else { return }

        let minute = TimeFormat.minutes(from: now)
        let today = DayKey.make(now)

        for reminder in config.reminders where reminder.enabled {
            guard let scheduled = reminder.effectiveTime(settings), scheduled == minute else {
                continue
            }

            let key = reminder.id.uuidString
            if config.fired[key] == today { continue }

            config.fired[key] = today
            onFire?(reminder)
            break
        }
    }

    /// Drops fire records that can no longer suppress anything.
    func prune(now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -3, to: now) else { return }
        let oldest = DayKey.make(cutoff)
        let pruned = config.fired.filter { $0.value >= oldest }
        if pruned.count != config.fired.count {
            config.fired = pruned
        }
    }

    // MARK: Editing

    func addCustom(at time: Int? = nil, settings: WorkdaySettings = .default) {
        let minute = time ?? settings.workEnd - 30
        config.reminders.append(
            Reminder(kind: .custom, time: minute, title: "提醒", message: "")
        )
    }

    func remove(_ reminder: Reminder) {
        config.reminders.removeAll { $0.id == reminder.id }
        config.fired[reminder.id.uuidString] = nil
    }

    func reset() {
        config = ReminderConfig()
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
