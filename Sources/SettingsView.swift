import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WorkdayModel
    @ObservedObject var reminders: ReminderCenter

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("工作时间") {
                row("上班") { timeField($model.settings.workStart) }
                row("下班") { timeField($model.settings.workEnd) }
            }

            Section("休息时间") {
                Toggle("启用午休", isOn: $model.settings.lunchEnabled)
                if model.settings.lunchEnabled {
                    row("开始") { timeField($model.settings.lunchStart) }
                    row("结束") { timeField($model.settings.lunchEnd) }
                }

                Toggle("启用晚餐休息", isOn: $model.settings.dinnerEnabled)
                if model.settings.dinnerEnabled {
                    row("开始") { timeField($model.settings.dinnerStart) }
                    row("结束") { timeField($model.settings.dinnerEnd) }
                }
            }

            Section("显示") {
                Toggle("桌面组件", isOn: $model.settings.showDesktopWidget)
                Toggle("灵动岛", isOn: $model.settings.showIsland)
                Text("灵动岛：平时隐藏在刘海里，鼠标移到刘海上会向下展开详情；点击可固定 / 取消固定。没有刘海的显示器会显示一个顶部小胶囊。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RemindersSettingsView(store: reminders, model: model)

            Section("工时记录") {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        switch LaunchAtLogin.set(enabled) {
                        case .success:
                            launchError = nil
                        case .failure(let error):
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }

                Text("记录下班时间需要 App 一直在运行：系统不提供锁屏历史，App 没运行时发生的锁屏观测不到。没观测到的日子会按排班下班时间结算。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                HStack {
                    Button("恢复默认设置") {
                        model.reset()
                    }
                    Spacer()
                }

                Text("所有百分比均为「已完成工作占比」。超过下班时间会显示已加班时长，凌晨 0 点自动重置；休息日显示休息状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !model.settings.isValid {
                    Label(
                        "时间设置存在冲突，请检查上班 / 下班与休息时间。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("关于") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppInfo.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Text("版本 \(AppInfo.version) (\(AppInfo.build))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                row("作者") {
                    Text(AppInfo.author)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .textSelection(.enabled)
                }

                HStack {
                    Text(AppInfo.copyright)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 740)
    }

    private func row<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            content()
        }
    }

    /// `trailingGap` keeps the field off the row's right edge; without it the
    /// drop-down sits flush against the section border.
    private func timeField(_ value: Binding<Int>) -> some View {
        TimePopupField(minutes: value)
            .padding(.trailing, 16)
    }
}
