import SwiftUI

// MARK: - Options

/// The minute values offered by the drop-down.
enum TimeOptions {
    static let minuteStep = 5

    /// Every `step` minutes on the hour, plus `current` when it does not land
    /// on the grid. Keeping the stored value in the list means opening the
    /// menu never rounds a setting that was typed in an older build.
    static func minutes(current: Int, step: Int = minuteStep) -> [Int] {
        let stride = max(1, step)
        var values = Array(Swift.stride(from: 0, to: 60, by: stride))
        let clamped = min(max(current, 0), 59)
        if !values.contains(clamped) {
            values.append(clamped)
            values.sort()
        }
        return values
    }
}

// MARK: - Field

/// An hour / minute pair of drop-downs that reads as one clock field.
///
/// Built from native `Picker`s rather than a `DatePicker`: the `.field` style
/// has no drop-down at all, and it lays the time out as one undifferentiated
/// text run. Two `.menu` pickers are the same class of control the `Form`
/// already lays out correctly, and they let the minute list step by five.
struct TimePopupField: View {
    @Binding var minutes: Int

    /// A menu picker in a grouped `Form` draws no bezel of its own on current
    /// macOS — just the text and a chevron — and it sizes itself to its widest
    /// item, ignoring `.frame(width:)`. So the box is drawn here: one rounded
    /// border around both drop-downs, whose padding controls the width.
    private let boxPadding = EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 6)

    var body: some View {
        HStack(spacing: 0) {
            Picker("小时", selection: hourBinding) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d", hour)).tag(hour)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Text(":")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Picker("分钟", selection: minuteBinding) {
                ForEach(TimeOptions.minutes(current: minutes), id: \.self) { minute in
                    Text(String(format: "%02d", minute)).tag(minute)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(boxPadding)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
        .help("选择时间")
    }

    private var hourBinding: Binding<Int> {
        Binding(
            get: { min(max(minutes, 0), 24 * 60 - 1) / 60 },
            set: { minutes = $0 * 60 + minutes % 60 }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { minutes % 60 },
            set: { minutes = minutes / 60 * 60 + $0 }
        )
    }
}
