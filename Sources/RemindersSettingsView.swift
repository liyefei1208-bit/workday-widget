import AppKit
import SwiftUI

/// Settings section for the island reminders.
struct RemindersSettingsView: View {
    @ObservedObject var store: ReminderCenter
    @ObservedObject var model: WorkdayModel

    var body: some View {
        Section("提醒") {
            Toggle("到点提醒", isOn: $store.config.enabled)

            Text("午休、晚餐、下班的时刻，灵动岛会展开提醒。上滑或点击可收起，3 秒后也会自动收起。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.settings.showIsland {
                Label(
                    "灵动岛已关闭，提醒不会显示。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if store.config.enabled {
                ForEach($store.config.reminders) { $reminder in
                    ReminderEditor(
                        reminder: $reminder,
                        settings: model.settings,
                        onDelete: deleteAction(for: reminder)
                    )
                }

                Button {
                    store.addCustom(settings: model.settings)
                } label: {
                    Label("添加自定义提醒", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Only user-added reminders can be removed; the three built-ins stay so
    /// their kind (and therefore their schedule link) cannot be lost.
    private func deleteAction(for reminder: Reminder) -> (() -> Void)? {
        guard reminder.kind == .custom else { return nil }
        return { store.remove(reminder) }
    }
}

// MARK: - Text field

/// A left-aligned text field.
///
/// SwiftUI's `TextField` cannot be used here: a `Form` lays controls out in a
/// label/value column and renders the value's text flush right, and it applies
/// that below SwiftUI's modifiers — `.multilineTextAlignment(.leading)` and a
/// plain text style both had no effect. Driving `NSTextField` directly sets the
/// alignment on the control itself.
struct LeftAlignedField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.alignment = .left
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: LeftAlignedField

        init(_ parent: LeftAlignedField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

// MARK: - One reminder

struct ReminderEditor: View {
    @Binding var reminder: Reminder
    var settings: WorkdaySettings
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: reminder.kind.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(reminder.kind.tint)
                    .frame(width: 16)

                Text(reminder.kind.label)
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除这个提醒")
                }

                Toggle("", isOn: $reminder.enabled)
                    .labelsHidden()
            }

            if reminder.enabled {
                row("时间") { timeControls }
                row("标题") {
                    LeftAlignedField(text: $reminder.title)
                }
                row("内容") {
                    LeftAlignedField(text: $reminder.message)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: Time

    @ViewBuilder
    private var timeControls: some View {
        HStack(spacing: 10) {
            if reminder.kind.followsScheduleByDefault {
                Toggle("跟随排班", isOn: followBinding)
                    .toggleStyle(.checkbox)
            }

            if reminder.time != nil || !reminder.kind.followsScheduleByDefault {
                TimePopupField(minutes: timeBinding)
            } else {
                Text(TimeFormat.minutes(reminder.effectiveTime(settings) ?? settings.workStart))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Off stores `nil`, which means "use whatever the schedule says".
    private var followBinding: Binding<Bool> {
        Binding(
            get: { reminder.time == nil },
            set: { follow in
                if follow {
                    reminder.time = nil
                } else {
                    reminder.time = reminder.effectiveTime(settings) ?? settings.workStart
                }
            }
        )
    }

    private var timeBinding: Binding<Int> {
        Binding(
            get: { reminder.effectiveTime(settings) ?? settings.workStart },
            set: { reminder.time = $0 }
        )
    }

    // MARK: Layout

    private func row<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            content()
        }
    }

}
