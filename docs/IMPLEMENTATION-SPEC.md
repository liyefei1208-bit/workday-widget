# 工作日 WorkdayWidget · 实现规格

> 用途：把 macOS 版的行为、算法、数据结构完整描述出来，以便在另一个环境
> （另一个平台、另一套技术栈、另一个 AI 会话）重新实现。
>
> 原实现：Swift + SwiftUI/AppKit，4286 行，macOS 14+。
> 本文不含 Swift 语法细节，只描述**必须一致的外部行为**和**必须一致的算法**。

---

## 1. 一句话定位

菜单栏常驻的小工具，用「今天的工作**已经完成了多少**」这一个数字，回答
「还要干多久」。

不是待办清单，不是日程表，不是番茄钟。它只做一件事：把一天的工作时间
切成可度量的块，实时显示完成比例。

---

## 2. 核心语义（最容易做错的地方）

**所有进度都是「已完成」，不是「剩余」。**

```
完成度 = (总工作分钟 - 剩余工作分钟) / 总工作分钟
```

9:30 上班时是 0%，19:30 是 100%。加班后**保持在 100%**，不会溢出。

界面上同时存在两个"时间"概念，绝不能混用：

| 概念 | 含义 | 示例（15:00） |
| --- | --- | --- |
| 剩余工作时间 | 还要专注干多久 | 270 分钟 |
| 距下班 | 墙钟时间，含晚餐休息 | 4 小时 30 分 |

原实现早期把后者标成"剩余"，用户误读成工作时长，后来改成明确标注「距下班」。
**新实现必须对这两个数字分别命名。**

---

## 3. 功能模块总览

| 模块 | 作用 | 必需 |
| --- | --- | --- |
| A 桌面组件 | 桌面层常驻卡片，三个进度环 | 可选 |
| B 顶部面板（灵动岛） | 悬停展开的详情面板 | 可选 |
| C 到点提醒 | 午休/晚餐/下班时展开提醒卡片 | 可选 |
| D 工时记录与统计 | 记录每天实际工时，按周/月/全部汇总 | 可选 |
| E 设置 | 时间配置、开关、提醒编辑 | 必需 |

A~D 都可以独立裁掉，E 和下面的**排班算法**是所有模块的共同底座。

---

## 4. 数据模型

### 4.1 设置 `WorkdaySettings`

所有时间都是**当天第几分钟**（0–1440 的整数），不用 `Date` / 时间戳。

| 字段 | 类型 | 默认值 | 含义 |
| --- | --- | --- | --- |
| `workStart` | Int | `570` | 上班 09:30 |
| `workEnd` | Int | `1170` | 下班 19:30 |
| `lunchEnabled` | Bool | `true` | 是否启用午休 |
| `lunchStart` | Int | `720` | 午休开始 12:00 |
| `lunchEnd` | Int | `780` | 午休结束 13:00 |
| `dinnerEnabled` | Bool | `true` | 是否启用晚餐休息 |
| `dinnerStart` | Int | `1080` | 晚餐 18:00 |
| `dinnerEnd` | Int | `1140` | 晚餐结束 19:00 |
| `showDesktopWidget` | Bool | `true` | 显示桌面组件 |
| `showIsland` | Bool | `true` | 显示顶部面板 |

**校验规则** `isValid`（设置界面用，不阻断计算）：

```
workEnd > workStart
若 lunchEnabled:  lunchEnd > lunchStart  且  workStart ≤ lunchStart 且 lunchEnd ≤ workEnd
若 dinnerEnabled: dinnerEnd > dinnerStart 且 workStart ≤ dinnerStart 且 dinnerEnd ≤ workEnd
```

即使配置非法，`Schedule` 也会做兜底（见 5.1），不崩、不出负数。

### 4.2 工时记录 `WorkDayRecord`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `dateKey` | String | `yyyy-MM-dd`，本地时区 |
| `workStart` | Int | 当天采用的上班时间（快照，不随设置变化） |
| `scheduledEnd` | Int | 当天排班下班时间（快照） |
| `clockOut` | Int | 实际下班，**可能 > 1440**（跨零点） |
| `source` | `"screenLock"` \| `"scheduled"` | 下班时间从哪来 |
| `workedMinutes` | Int | 实际工作时长 |
| `scheduledMinutes` | Int | 排班工作时长 |
| `recordedAt` | ISO8601 String | 写入时间 |

派生值（不落盘）：
```
overtimeMinutes = max(0, workedMinutes - scheduledMinutes)
shortMinutes    = max(0, scheduledMinutes - workedMinutes)
```

**为什么要快照 `workStart` / `scheduledEnd`**：用户中途改了排班，历史记录不能跟着变。
新实现必须同样固化。

### 4.3 提醒 `Reminder` / `ReminderConfig`

```jsonc
Reminder {
  id: UUID (string)
  kind: "lunch" | "dinner" | "workEnd" | "custom"
  enabled: bool            // 默认 true
  time: Int | null         // null = 跟随排班
  title: String
  message: String
}
```

三条内置默认值：

| kind | title | message |
| --- | --- | --- |
| lunch | 午休时间到 | 去吃个饭，回来再继续 |
| dinner | 晚餐休息 | 起来活动一下，吃点东西 |
| workEnd | 下班了 | 今天辛苦了，早点休息 |

```jsonc
ReminderConfig {
  enabled: bool                 // 总开关，默认 true
  reminders: [Reminder]         // 默认 = 上面三条，time 均为 null
  fired: { [reminderID]: "yyyy-MM-dd" }   // 今天已触发过的记录
}
```

---

## 5. 排班与进度算法

### 5.1 工作区间 `Schedule`

输入 `WorkdaySettings`，输出若干段**净工作区间**。

```
构造：
  start = clamp(workStart, 0, 1440)
  end   = clamp(workEnd,   0, 1440)
  若 end < start: 交换两者                      // 兜底，不报错

  breaks = []
  若 lunchEnabled  且 lunchEnd   > lunchStart:   breaks += [lunchStart,  lunchEnd]
  若 dinnerEnabled 且 dinnerEnd  > dinnerStart:  breaks += [dinnerStart, dinnerEnd]
  breaks 按起点排序

workRanges = [start, end] 依次减去每个 break
  减法：区间 [a,b] 减去 [c,d]
    若 d ≤ a 或 c ≥ b → 原样保留
    否则 → 保留 [a, min(c,b)]（若非空）和 [max(d,a), b]（若非空）
```

默认设置下：`[570,720] [780,1080] [1140,1170]`，共 **480 分钟**。

```
午/下午分界 midday =
  若 lunchEnabled 且 lunchEnd > lunchStart: clamp(lunchStart, workStart, workEnd)
  否则: clamp(720, workStart, workEnd)          // 无午休时用中午 12:00

morningRanges   = workRanges ∩ [workStart, midday]
afternoonRanges = workRanges ∩ [midday, workEnd]

morningTotal   = Σ morningRanges 长度
afternoonTotal = Σ afternoonRanges 长度
totalWork      = morningTotal + afternoonTotal
```

边界约定：区间**左闭右开**，`[start, end)`。

### 5.2 剩余时间

```
remaining(range, m) =
  若 m ≤ range.start → range.length
  若 m ≥ range.end   → 0
  否则               → range.end - m

remainingWork(m)      = Σ remaining(r, m) for r in workRanges
remainingMorning(m)   = Σ ... for r in morningRanges
remainingAfternoon(m) = Σ ... for r in afternoonRanges
```

`m` 是**带小数的分钟**：`hour*60 + minute + second/60`。用小数是为了让进度环
平滑推进，整点跳跃会让人以为卡住了。

### 5.3 进度

```
progress(total, remaining) =
  若 total ≤ 0 → 0
  否则 clamp((total - remaining) / total, 0, 1)
```

百分比 = `round(progress * 100)`，只用于显示。
**非工作日所有进度强制为 0，所有 remaining 强制为 0。**

### 5.4 验证用例

默认排班下（480 分钟总工时）：

| 时刻 | 已工作 | 整体 | 上午 | 下午 |
| --- | --- | --- | --- | --- |
| 09:30 | 0 | 0% | 0% | 0% |
| 12:00 | 150 | 31% | 100% | 0% |
| 15:00 | 270 | 56% | 100% | 36% |
| 19:30 | 480 | 100% | 100% | 100% |
| 21:00（加班） | 480 | 100% | 100% | 100% |

---

## 6. 日状态机 `DayPhase`

判定**顺序**很重要，不能重排：

```
1. 不是工作日（weekday ∉ {2,3,4,5,6}，即周一至周五）→ weekend    「休息日」
2. m < workStart                                      → beforeWork 「未开始」
3. m ≥ workEnd:
      m > workEnd ? overtime「加班中」 : afterWork「已下班」
4. lunchEnabled  且 lunchEnd > lunchStart  且 lunchStart ≤ m < lunchEnd  → lunchBreak「午休中」
5. dinnerEnabled 且 dinnerEnd > dinnerStart 且 dinnerStart ≤ m < dinnerEnd → dinnerBreak「休息中」
6. 其余 → working「工作中」
```

要点：

- 恰好等于 `workEnd` 时是 `afterWork`，**不是** `overtime`。
- 加班时长 `overtimeMinutes = max(0, m - workEnd)`，仅在 `phase == overtime` 时非零。
- 加班时长按**墙钟**算，不扣休息。
- 跨过 0:00 自然归零，因为快照永远基于"今天"重建，不需要额外重置逻辑。

### 6.1 状态配色

| phase | 状态色 |
| --- | --- |
| working | `#33CC78` |
| lunchBreak / dinnerBreak | 橙色（系统 orange） |
| beforeWork | 蓝色（系统 blue） |
| afterWork | 次要文字色 |
| overtime | `#FF9433` |
| weekend | `#A391FC` |

整体进度环在 `overtime` 时改用 `#FF9433`，其余时候用 `#33CC78`。

---

## 7. 工时记录与结算

### 7.1 信号源

**下班时间 = 当天最后一次锁屏**。

原实现监听 macOS 的 `com.apple.screenIsLocked` 分布式通知（非公开 API，但稳定多年）。
**全平台通用事实：操作系统都不提供锁屏历史查询**，只能实时监听。

跨平台等价物：

| 平台 | 锁屏/离开信号 |
| --- | --- |
| macOS | `DistributedNotificationCenter` + `com.apple.screenIsLocked` |
| Windows | `WTSRegisterSessionNotification` + `WM_WTSSESSION_CHANGE`（`WTS_SESSION_LOCK`） |
| Linux | `org.freedesktop.login1` D-Bus `Lock` 信号，或 `loginctl` 监听 |
| 无桌面权限时 | 兜底：闲置检测 + 退化为排班时间 |

### 7.2 锁屏归属（跨零点）

```
attribution(lockTime) ->
  m = minuteOfDay(lockTime)
  若 m < 360（06:00 前）:
     返回 (前一天, m + 1440)     // 跨零点加班，记到前一天
  否则:
     返回 (当天, m)
```

只接受工作日（周一至周五）的锁屏，非工作日直接丢弃。

同一天多次锁屏：**只保留最晚的一次**（`existing >= minute` 时忽略）。
多次解锁再锁屏是常态，取最后一个是唯一合理的解释。

### 7.3 结算时机

> 「第二天上班时间开始」时才结算前一天。
> 这是拿到前一天完整锁屏记录的最早时机。

```
reconcile(now):
  today    = startOfDay(now)
  yesterday = today - 1 天
  firstDay = startOfDay(firstDayKey)        // 日志首次建立的日期

  cursor = 若有记录 ? max(firstDay, 最新记录日期 + 1) : firstDay

  while cursor ≤ yesterday:
      next = cursor + 1 天
      若 cursor 不是工作日 → continue
      若 cursor 已有记录   → continue

      due = next 当天 的 workStart 时刻
      若 now < due → continue

      追加记录 cursor（见 7.4）

  清理 pendingLock 中 7 天以前的数据
```

**`firstDayKey` 的意义**：首次运行时写入当天日期，早于它的日期永远不结算。
否则程序第一次启动就会凭空生成一堆没有观测依据的历史记录。

触发时机：① 应用启动 ② 系统唤醒 ③ 每分钟 tick。三者都要。

### 7.4 生成一条记录

```
lock = pendingLock[dateKey]

若 lock 存在 且 lock > workStart:
    clockOut = lock
    source   = "screenLock"
否则:
    clockOut = workEnd
    source   = "scheduled"      // 没有观测到，退回排班，并明确标注

workedMinutes = round(
      (totalWork - remainingWork(clockOut))     // 排班内已工作
    + max(0, clockOut - workEnd)                // 加班部分（墙钟）
)

scheduledMinutes = round(totalWork)
```

**回退必须标注来源**。统计里单独显示"其中 N 天来自锁屏"，不能把排班值
伪装成实际值。

验证（真实数据，来自原实现的 `worklog.json`）：
```
workEnd=1170, clockOut=1179(19:39), totalWork=480
→ (480 - 0) + 9 = 489 分钟 = 8 小时 9 分 ✓
```

### 7.5 持久化

路径：`<ApplicationSupport>/Workday/worklog.json`
（Windows: `%APPDATA%\Workday\worklog.json`；Linux: `~/.local/share/Workday/worklog.json`）

```jsonc
{
  "version": 1,
  "firstDayKey": "2026-10-28",
  "pendingLock": {
    "2026-10-28": 1179          // dateKey -> 当天最晚一次锁屏的分钟数
  },
  "records": [
    {
      "dateKey": "2026-10-28",
      "workStart": 570,
      "scheduledEnd": 1170,
      "clockOut": 1179,
      "source": "screenLock",
      "workedMinutes": 489,
      "scheduledMinutes": 480,
      "recordedAt": "2026-10-29T01:30:00Z"
    }
  ]
}
```

- 保留上限 **800 条**记录（写入时截断）。
- `pendingLock` 只保留最近 **7 天**。
- 原子写入（先写临时文件再 rename）。
- 解析失败时：忽略旧数据并提示，**不要**清空覆盖用户文件。

### 7.6 统计

| 范围 | 定义 |
| --- | --- |
| 本周 | `date ≥ 本周起始日`（跟随系统周首日） |
| 本月 | `date ≥ 本月初` |
| 全部 | 无过滤 |

汇总字段：天数、总实际、总排班、总加班、总缺口、**其中锁屏来源的天数**、
日均（`总实际 / 天数`，天数为 0 时返回 0）。

---

## 8. 到点提醒

### 8.1 触发规则

```
evaluate(now):
  若 config.enabled == false → 返回
  若 weekday ∉ {2..6}        → 返回      // 周末不打扰

  m     = minuteOfDay(now)
  today = dateKey(now)

  for r in config.reminders:
      若 r.enabled == false → 跳过
      t = r.effectiveTime(settings)
      若 t == null 或 t != m → 跳过
      若 config.fired[r.id] == today → 跳过

      config.fired[r.id] = today
      触发(r)
      break                                // 一分钟只触发一条
```

`effectiveTime`：

```
若 r.time != null → r.time                            // 显式时间优先
否则按 kind:
  lunch  → lunchEnabled   ? lunchStart : null         // 午休关掉则无提醒
  dinner → dinnerEnabled  ? dinnerStart : null
  workEnd→ workEnd
  custom → null                                       // 自定义必须显式设时间
```

### 8.2 收起方式（三条并存）

1. **上滑**：拖动位移 ≥ 20pt 且方向向上
2. **点击**：点击期间只关闭提醒，不切换"固定/取消固定"
3. **自动**：**3 秒**后收起

自动收起的必要性：没人理它的话，提醒会一直盖住屏幕顶部直到下一条。

### 8.3 界面

卡片内容（垂直居中）：

```
  [图标圆 52pt]     标题 15.5pt
                    正文 11.5pt
                    ⌃ 上滑收起  (提示)
```

图标与配色按 kind：

| kind | 图标语义 | 颜色 |
| --- | --- | --- |
| lunch | 刀叉 | `#FFB042` |
| dinner | 月亮 | `#A391FC` |
| workEnd | 房子 | `#33CC78` |
| custom | 铃铛 | `#599EFF` |

---

## 9. UI 规格

### 9.1 配色（全部 RGB 0–1 换算为 hex，便于跨栈复用）

| 名称 | RGB | Hex |
| --- | --- | --- |
| 主题绿 accent | 0.20, 0.80, 0.47 | `#33CC78` |
| 休息紫 rest | 0.64, 0.57, 0.99 | `#A391FC` |
| 加班橙 overtime | 1.00, 0.58, 0.20 | `#FF9433` |
| 上午环 | 1.00, 0.69, 0.26 | `#FFB042` |
| 下午环 | 0.35, 0.62, 1.00 | `#599EFF` |
| 轨道 | 前景色 9% 透明度 | — |

### 9.2 进度环

```
大环：直径 100pt，线宽 10pt，圆头端点，-90° 起（12 点方向）
      主色 68% 透明度 → 主色 的线性渐变（左上 → 右下）
      动画 0.55s easeOut
小环：直径 36pt，线宽 5pt，纯色，其余同上
      从 12 点顺时针增长
```

### 9.3 桌面组件

```
卡片     292 × 260pt，圆角 26pt（continuous），内边距 18pt
阴影     四周预留 20pt
背景     半透明材质 + 顶部白色高光渐变 + 0.8pt 描边
内容     三个进度环（整体/上午/下午）+ 状态文案 + 加班提示 + 作者水印
水印     "yefei.li"，低对比度，右对齐，不干扰读数
```

窗口层级：**在桌面图标之上、普通窗口之下**（真正的"小组件"语义）。
macOS 上取 `CGWindowLevelForKey(.desktopIconWindow) + 1`。

窗口属性：`borderless` + `canJoinAllSpaces` + `stationary` + `ignoresCycle`
（跨 Space 常驻、不随切换滑动、不进 ⌘Tab）。

可拖动，位置持久化，右键菜单：设置 / 隐藏 / 退出。

### 9.4 顶部面板（"灵动岛"）

这是 macOS 特化设计，其他平台需重新设计交互（见 §10.3）。

```
凹角半径 flare           9pt
收起态底圆角             10pt
展开态底圆角             22pt
收起态宽度 = 刘海宽度（无刘海屏：190pt）
展开态宽度               320pt（+ 两侧 flare）
展开态详情高度           130pt
阴影留白                 24pt
悬停容错                 5pt
窗口尺寸                 展开态 + 阴影留白，动画期间不 resize
```

关键实现约束（原实现踩过的坑）：

- 窗口尺寸**固定**，展开/收起只改内部形状的 frame、圆角、裁切。
  用窗口 resize 做动画会掉帧。
- 收起态必须**完全藏进硬件刘海**，否则用户会看见一个黑块。
- 刘海不一定正好在屏幕中心，要按实际 `auxiliaryTopLeftArea/RightArea` 计算偏移。
- 悬停检测用**鼠标坐标轮询**，不要用 `onHover`：藏在刘海下方的窗口收不到
  enter/exit 事件。
- 窗口必须是非激活面板（`.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`），
  否则点击会造成前台应用失焦。
- 层级取 `mainMenu + 3`，并加 `fullScreenAuxiliary`，让它在全屏应用上也能浮出。

### 9.5 菜单栏 / 托盘

图标显示迷你进度环 + 百分比数字。菜单：

```
显示/隐藏桌面组件
显示/隐藏顶部面板
测试提醒            ← 立即弹一条，便于调试
工作时间统计…        ⌘T
设置…                ⌘,
退出
```

---

## 10. 平台集成点

这是移植时**必须逐个替换**的部分，原实现全部绑定 macOS。

| 能力 | macOS（原实现） | Windows | Linux | 备注 |
| --- | --- | --- | --- | --- |
| 常驻托盘 | `NSStatusItem` | `Shell_NotifyIcon` / `NotifyIcon` | StatusNotifierItem | — |
| 浮层窗口 | `NSPanel` 非激活 | `WS_EX_NOACTIVATE` + `WS_EX_TOOLWINDOW` | `_NET_WM_WINDOW_TYPE_UTILITY` | 不要抢焦点 |
| 贴桌面层级 | `NSWindow.Level(.desktopIcon)` | `SetParent(Progman/WorkerW)` | `_NET_WM_WINDOW_TYPE_DESKTOP` | 各家做法都不同 |
| 锁屏信号 | `com.apple.screenIsLocked` | `WM_WTSSESSION_CHANGE` | D-Bus `loginctl` | 见 §7.1 |
| 唤醒通知 | `NSWorkspace.didWake` | `WM_POWERBROADCAST` | D-Bus `PrepareForSleep` | 用于补算 |
| 开机自启 | `SMAppService` | 注册表 `HKCU\...\Run` | `~/.config/autostart/*.desktop` | 要可关闭 |
| 配置存储 | `UserDefaults` | `HKCU` 注册表 / JSON | `~/.config/workday/` | — |
| 毛玻璃背景 | `.ultraThinMaterial` | `DwmEnableBlurBehindWindow` | 视合成器而定 | 无则退化为纯色 + 透明度 |

### 10.3 「灵动岛」在其他平台怎么办

macOS 的刘海是**硬件**，没有等价物。不建议硬仿一个假刘海。可选方案：

1. **托盘弹出面板**（推荐）：点托盘图标在屏幕右上角展开一张卡片，行为与灵动岛
   一致（展开详情 + 提醒 + 上滑收起）。
2. **屏幕顶部细条**：默认 2pt 几乎不可见，鼠标靠近顶部时展开——更接近原体验，
   但会干扰全屏应用和浏览器标签栏，慎用。
3. **干脆去掉**：只保留桌面组件 + 通知系统提醒。

提醒功能在没有灵动岛时可退化为**系统通知**（Windows Toast / libnotify），
但会丢失"上滑收起"的交互感。

---

## 11. 持久化键值

| 内容 | 键 / 路径 |
| --- | --- |
| 时间设置 | `workday.settings.v1`（JSON blob） |
| 提醒配置 | `workday.reminders.v1`（JSON blob） |
| 工时记录 | `Workday/worklog.json`（独立文件） |

命名带 `v1` 后缀，为将来迁移留余地。

---

## 12. 测试用例

原实现有 **40 项自检**（23 项工时 + 17 项提醒），无 UI、无文件以外依赖，
纯函数校验，失败返回非 0 退出码。新实现**至少覆盖以下场景**。

### 12.1 工时结算（23 项）

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 周二锁屏 21:00 | 已结算出记录 |
| 2 | 同日 | `clockOut == 1260` |
| 3 | 同日 | `source == screenLock` |
| 4 | 同日 | `workedMinutes == 570`（9h30m = 8h + 1h30 加班） |
| 5 | 周一无锁屏 | `clockOut == 1170` 回退排班 |
| 6 | 周一 | `source == scheduled` |
| 7 | 周一 | `workedMinutes == 480` |
| 8 | 当天（未到次日上班） | **不结算** |
| 9 | 首次运行日之前 | **不编造记录** |
| 10 | 重复调用 reconcile | 记录数不变（幂等） |
| 11 | 结算后 | 文件已写入 |
| 12 | 重新加载 | 记录数一致 |
| 13 | 重新加载 | `firstDayKey` 保持 |
| 14–23 | 零点后锁屏、06:00 边界、只保留最晚锁屏、非工作日锁屏丢弃、跨多天补算、超时上限、统计汇总等 | 见 §7 规则 |

### 12.2 提醒（17 项）

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 午休未设时间 | 跟随排班 12:00 |
| 2 | 设显式 12:30 | 覆盖排班 |
| 3 | 清除显式时间 | 回到排班 |
| 4 | 关闭午休 | 无提醒时间 |
| 5 | 自定义无时间 | 永不触发 |
| 6 | 11:59 | 不触发 |
| 7 | 12:00 | 触发午休 |
| 8 | 同一分钟再次 evaluate | 不重复触发 |
| 9 | 18:00 | 触发晚餐 |
| 10 | 19:30 | 触发下班 |
| 11 | 次日 12:00 | 重新触发 |
| 12 | 周末 12:00 | 不触发 |
| 13 | 单条 `enabled=false` | 不触发 |
| 14 | 总开关关 | 全部不触发 |
| 15 | 恢复总开关 | 正常触发 |
| 16 | 触发后 | `fired` 已持久化 |
| 17 | 重启（重载配置）同日 | 不重复触发 |

### 12.3 建议新增（原实现没有）

- 排班算法：非法配置（下班早于上班、午休越界）不崩溃、不出负数
- 进度单调性：随时间为单调不减（0→100% 不回退）
- 跨天重置：23:59 → 00:01 进度归零
- 时区变化：系统时区切换后 `dateKey` 不自相矛盾

---

## 13. 已知限制与设计取舍

这些是**有意的选择**，不是 bug，实现时不要"顺手修掉"：

1. **「最后一次锁屏」不区分「下班」和「单纯离开电脑」。**
   晚上 23:00 还在用然后锁屏，就记成 23:00 下班。要区分需要应用活跃度/
   IDE 活动等更强信号，超出当前范围。

2. **应用不在运行时的锁屏观测不到。**
   系统不提供锁屏历史。那几天回退到排班值，并明确标注来源。

3. **只认周一至周五。** 不读节假日日历，不做调休。需要的话是独立模块。

4. **不结算「今天」。** 今天的数据永远是"进行中"，统计里只算已结算的完整天。

5. **灵动岛窗口常驻内存**，即使收起。这是换取瞬间展开的代价。

6. **macOS 版没有代码签名公证**，首次打开需绕过 Gatekeeper。

---

## 14. 原实现文件结构（对照参考）

```
Sources/
├── main.swift                  (489) 入口 / CLI / 预览渲染 / 自检
├── AppDelegate.swift           (829) 窗口、托盘、刘海定位、悬停、调度
├── Model.swift                 (403) 设置、排班、快照、格式化   ← 最可复用
├── WorkLog.swift               (436) 锁屏监听、结算、JSON 存储   ← 逻辑可复用
├── Reminders.swift             (206) 提醒数据与触发规则         ← 逻辑可复用
├── IslandView.swift            (657) 顶部面板形状与交互
├── WidgetView.swift            (272) 桌面组件 UI
├── StatsView.swift             (354) 统计界面
├── SettingsView.swift          (149) 设置面板
├── RemindersSettingsView.swift (216) 提醒设置
├── DesignSystem.swift          (132) 配色、进度环、玻璃背景     ← 可直接翻译
├── AppIconView.swift            (81) 图标绘制
├── LaunchAtLogin.swift          (30) 登录项
├── AppInfo.swift                (24) 作者 / 版本
└── Notifications.swift           (8) 内部通知
```

**移植优先级**：`Model.swift` + `WorkLog.swift` 的数学部分 + `Reminders.swift`
的规则，约 800 行可几乎逐行翻译；其余是视觉与平台集成，需要按新平台重写。

### 参考命令（原实现提供）

```bash
# 校验算法，失败返回非 0
<app> --log-selftest
<app> --reminder-selftest

# 打印某时刻的计算结果
<app> --dump --at 15:30

# 渲染预览图（用于视觉回归对比）
<app> --render out.png --at 10:45 [--island] [--compact] [--light] [--weekend]
<app> --render-stats out.png
<app> --render out.png --island --reminder lunch
```

建议新实现同样提供 `--dump` 和纯函数自检，因为**算法正确性不可能靠看 UI 判断**。

---

## 15. 数据文件位置（迁移用）

| 平台 | 位置 |
| --- | --- |
| macOS | `~/Library/Application Support/Workday/worklog.json` |
| Windows | `%APPDATA%\Workday\worklog.json` |
| Linux | `~/.local/share/Workday/worklog.json` |

`worklog.json` 格式与平台无关，可跨平台直接复制迁移。
设置与提醒配置存在平台配置库里，迁移需要单独导出。
