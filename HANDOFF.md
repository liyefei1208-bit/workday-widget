# 工作日进度组件 — 功能交接说明

> 项目路径：`/Users/liyefei/workspace/workday-widget`
> 应用：`WorkdayWidget.app`（原生 macOS，SwiftUI + AppKit）
> 状态：**全部功能已实现**。灵动岛定位已按「隐藏在刘海里」完成，见第 0 节。

---

## 0. 灵动岛定位（已完成）

### 根因

此前灵动岛把窗口顶边放在 `screen.visibleFrame.maxY + 10`，也就是**菜单栏下方**，
所以它永远是一个悬浮在菜单栏下面的独立胶囊，不可能被刘海遮盖。
无论怎么调形状和裁切都无法满足「正常状态下隐藏在灵动岛（刘海）下」。

### 修复

窗口顶边改为与屏幕**物理顶边**对齐，并把收起态尺寸设成真实刘海尺寸：

```
screen.frame            = (0, 0, 1512, 982)
screen.safeAreaInsets.top = 32
真实刘海                 = x 665…850, y 950…982   (185 × 32)
收起态灵动岛             = x 665…850, y 950…982   ← 与刘海完全重合
展开态灵动岛             = x 588.5…926.5, y 820…982  (338 × 162，body 320)
面板窗口                 = 386 × 186，origin (564.5, 796)，顶边 = screen.frame.maxY
```

要点：

1. 窗口顶边 `y = screen.frame.maxY - windowHeight`，即顶边贴屏幕物理顶边。
2. 收起态尺寸 = `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 推出的刘海宽度
   和 `safeAreaInsets.top` 高度，被硬件刘海完全遮盖。
3. 按**刘海实际中心**对齐，不是屏幕中心。本机刘海中心在 757.5，屏幕中心 756，
   差 1.5pt；不修正会在刘海左侧露出 1.5pt 黑边。
4. 窗口层级 `NSWindow.Level.mainMenu + 3`，才能盖住菜单栏。
5. 窗口尺寸固定（386 × 186），展开 / 收起**不 resize 窗口**，
   只有 SwiftUI 形状的 frame / 圆角 / 裁切在动画。
6. 悬停检测用鼠标坐标（`NSEvent.mouseLocation` + 全局/本地 mouseMoved 监听
   + 0.2s 轮询兜底），**不能用 `onHover`**：刘海下方的窗口收不到常规的
   mouse-entered / exited 事件。
7. 没有刘海的显示器（外接屏）没有藏身处，退化为屏幕顶边一个
   190 × 菜单栏高度的小胶囊，常驻显示迷你进度环和百分比。

### 形状

`NotchIslandShape`：顶边与屏幕边缘齐平、全宽；顶部两角是**凹角**（flare 9pt）
融入菜单栏；底部两角圆角（收起 10pt / 展开 22pt）。
竖直侧边内缩 flare，所以可见 body 宽度 = `rect.width - 2 * flare`。

### 展开态布局

```
┌──────────────────────────────────────────┐
│ 工作中          [刘海遮挡区]        19:41 │  ← 32pt，中间留空给硬件刘海
├──────────────────────────────────────────┤
│  ╭───╮   ◯ 上午  9:30–12:00      100%    │
│  │56%│   ◯ 下午 13:00–19:30       36%    │  ← 130pt 详情
│  ╰───╯                                   │
│ 已加班 30 分钟              注意休息      │
└──────────────────────────────────────────┘
```

状态文案和时间放在刘海左右两侧；刘海正下方不放内容。
详情区高度按内容实际尺寸定（130pt），页脚紧贴圆环下方，不留大段空白。

---

## 1. 产品功能总览

### 1.1 桌面组件（已实现）

一个贴桌面层级的 macOS 小窗口，展示当天工作进度。

- 无边框玻璃卡片，圆角约 26pt。
- 窗口层级：`CGWindowLevelForKey(.desktopIconWindow) + 1`（桌面图标层之上，普通窗口之下）。
- 可拖动，位置通过 `setFrameAutosaveName` 自动保存。
- 始终不占 Dock（`LSUIElement = true`）。
- 右键菜单：设置、隐藏组件、退出。
- 内容：
  - 顶部：工作日 / 今日、上下班时间、当前时间。
  - 大圆环：整体已完成百分比。
  - 两个小圆环：上午已完成百分比、下午已完成百分比。
  - 底部：状态点 + 状态文案 + 已工作 / 距上班 / 已加班时长。

### 1.2 灵动岛（已实现）

隐藏在 MacBook 刘海里的进度组件；鼠标移到刘海上时向下展开详情，点击固定。
定位细节见第 0 节。

1. **正常态（收起）**
   - 灵动岛尺寸等于真实刘海并与之重合，被硬件完全遮盖，看不出有东西在那里。
   - 进度仍可从菜单栏图标（迷你进度环 + 百分比）查看。
   - 不激活应用、不抢焦点，所有 Space 可见，层级在菜单栏之上。

2. **悬停展开**
   - 鼠标移到刘海上即展开；同一个黑色形状从屏幕顶边向下生长。
   - 详情全部 `clipShape` 在形状内部，形状外没有任何内容。
   - 刘海所在的中间区域留空（硬件遮挡），状态文案 / 时间放在刘海左右两侧。

3. **移开收起**
   - 形状收回刘海内，详情被完全裁掉。
   - 窗口尺寸不变，动画只由形状驱动，无卡顿。

4. **点击固定**
   - 点击展开后的岛体可固定；再次点击取消固定。
   - 收起态位于硬件刘海下方，无法点击，这是预期行为（改用悬停或菜单栏）。

5. **动画**
   - 打开 `.spring(response: 0.42, dampingFraction: 0.8)`
   - 收起 `.spring(response: 0.45, dampingFraction: 1.0)`（无回弹）
   - 内容固定尺寸，不参与布局动画。

### 1.3 进度计算（已实现）

默认时间：

| 项目 | 时间 |
| --- | --- |
| 上班 | 09:30 |
| 上午工作 | 09:30 – 12:00（150 分钟） |
| 午休 | 12:00 – 13:00 |
| 下午工作 | 13:00 – 19:30（330 分钟，含晚餐休息） |
| 晚餐休息 | 18:00 – 19:00 |
| 下班 | 19:30 |

- 总工作时间：480 分钟。
- 上午工作：150 分钟。
- 下午工作：330 分钟（13:00–18:00 + 19:00–19:30）。
- 所有百分比均为**已完成进度**：
  - 整体 = 已工作 / 480
  - 上午 = 上午已工作 / 150
  - 下午 = 下午已工作 / 330
- 参考结果：
  - 10:45 → 整体 16%、上午 50%、下午 0%
  - 12:30 → 整体 31%、上午 100%、下午 0%
  - 15:00 → 整体 56%、上午 100%、下午 36%
  - 18:30 → 整体 94%、上午 100%、下午 91%
  - 19:30 → 100% / 100% / 100%
- 19:30 之后进入「加班中」，显示 `已加班 X 小时 X 分`，整体圆环变橙色。
- 加班时长 = 当前时间 - 19:30；凌晨 0 点日期切换后自动重置为 0。
- 周一至周五为工作日；周末显示「休息日 / 下一个工作日」。
- 阶段：weekend / beforeWork / working / lunchBreak / dinnerBreak / afterWork / overtime。

### 1.4 设置（已实现）

菜单栏 → 设置…，或右键组件 → 设置：

- 上班 / 下班时间
- 启用午休 + 起止时间
- 启用晚餐休息 + 起止时间
- 显示桌面组件 / 显示灵动岛
- 恢复默认设置
- 时间非法时显示警告
- 配置持久化到 `UserDefaults`（key: `workday.settings.v1`）

### 1.5 菜单栏（已实现）

- 菜单栏图标：迷你圆形进度环 + 已完成百分比。
- 菜单：显示/隐藏桌面组件、显示/隐藏灵动岛、设置…、退出工作日。

---

## 2. 当前实现状态

### 已实现

- 工作日计算、加班、跨零点重置、周末状态。
- 桌面组件卡片、圆环 UI、上下文菜单、位置持久化。
- 菜单栏状态项与菜单。
- 设置窗口。
- 灵动岛：刘海对齐定位、悬停展开、点击固定、无刘海显示器退化为顶部胶囊。
- 预览/校验工具：
  - `./build.sh --preview`
  - `--dump --at HH:mm`
  - `--dump-island`（打印每块屏幕的刘海与灵动岛实际坐标）
  - `--render <png> [--at HH:mm] [--weekend] [--island] [--compact] [--light] [--no-notch]`
  - `--expand-island`（启动即固定展开）、`--show-settings`

### 灵动岛的迭代历史（排查记录）

1. 胶囊 + 下方弹出面板 → 拒绝：“挂在灵动岛下”。
2. 单个 morphing 卡片（190×36 → 320×196）→ 仍未被遮盖。
3. 胶囊 + 更宽的卡片放在胶囊后面（320 宽）→ 卡片比胶囊宽，顶部两侧必然露出。
4. 单一 `IslandShape` + `clipShape` → 形状对了，但仍未被遮盖。
5. **根因**：窗口顶边一直放在 `visibleFrame.maxY + 10`（菜单栏下方），
   所以它是一个悬浮在菜单栏下的独立胶囊，和刘海毫无关系。
6. **修复**：窗口顶边对齐 `screen.frame.maxY`，收起态尺寸 = 真实刘海尺寸，
   并按刘海实际中心对齐。详见第 0 节。

---

## 3. boringNotch 的参考实现（已验证）

项目：<https://github.com/TheBoredTeam/boring.notch>（GPL-3.0，只参考架构，不要复制代码）

关键点：

1. **窗口固定为展开尺寸**，只在顶部定位；展开/收起**不 resize 窗口**。
   - `sizing/matters.swift`：`windowSize = openNotchSize + shadowPadding`
   - `boringNotchApp.swift`：`positionWindow` 把窗口顶边贴到屏幕顶部。
2. **整个面板是一个黑色 `NotchShape`**：
   ```swift
   NotchLayout()
       .background(.black)
       .clipShape(currentNotchShape)
   ```
   所有内容都在形状内部；形状外没有可见内容。
3. **形状顶部锚定，向下生长**；收起时形状很小，内容被裁掉；展开时形状变大，内容被揭开。
4. **开/收 spring**：
   - 打开：`spring(response: 0.42, dampingFraction: 0.8)`
   - 收起：`spring(response: 0.45, dampingFraction: 1.0)`
5. 窗口是透明、非激活的 `NSPanel`，层级在菜单栏之上：
   - `boringNotch/components/Notch/BoringNotchWindow.swift`
   - `level = .mainMenu + 3`
   - `isFloatingPanel = true`、`isOpaque = false`、`backgroundColor = .clear`

参考文件：

- [NotchShape.swift](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/components/Notch/NotchShape.swift)
- [ContentView.swift](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/ContentView.swift)
- [BoringNotchWindow.swift](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/components/Notch/BoringNotchWindow.swift)
- [boringNotchApp.swift](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/boringNotchApp.swift)
- [sizing/matters.swift](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/sizing/matters.swift)

**建议的技术方案：**

- 顶部居中的透明 `NSPanel`，固定尺寸（展开尺寸 + shadow padding）。
- 用单一 `IslandShape`/`NotchShape`（上下圆角可动画）作为唯一的黑色可见表面。
- 所有内容固定尺寸，`.clipShape(shape)`；形状 frame/圆角/裁切路径做动画。
- 顶部 36pt 是紧凑 header；详情内容在下面，收起时完全被形状裁掉。
- 形状外区域点击穿透；显示区域用 `contentShape` / 自定义 hitTest 限制。
- 窗口尺寸在展开前/收起后瞬时切换，动画期间不变。

---

## 4. UI 规格

### 灵动岛

- 收起：等于真实刘海（本机 185 × 32）；展开：338 × 162（body 320，32 刘海带 + 130 详情）。
- 位置：窗口顶边贴屏幕物理顶边，按刘海实际中心水平对齐；窗口固定 386 × 186。
- 形状：`NotchIslandShape`，顶边齐平全宽 + 9pt 凹角，底部圆角（收起 10 / 展开 22）。
- 背景：纯黑（与刘海一致），展开时带黑色阴影。
- 字体：SF Pro Rounded / SF Pro；数字等宽。
- 颜色：
  - 整体：绿色 `rgb(0.20, 0.80, 0.47)`
  - 上午：橙色 `rgb(1.00, 0.69, 0.26)`
  - 下午：蓝色 `rgb(0.35, 0.62, 1.00)`
  - 加班：橙色 `rgb(1.00, 0.58, 0.20)`
  - 休息日：紫色 `rgb(0.64, 0.57, 0.99)`
- 收起内容：有刘海时不显示任何内容（被硬件遮盖）；无刘海时显示
  17pt 迷你圆环 + 12.5pt 百分比 + 5pt 状态点。
- 展开内容：
  - 刘海带（32pt）：左侧状态文案、右侧当前时间，中间留空给硬件刘海。
  - 86pt 整体圆环（中心 21pt 百分比 + “已完成”）。
  - 上午/下午行：28pt 小圆环 + 时段 + 时间范围 + 百分比。
  - 底部：已工作 / 剩余，或已加班 / 注意休息（紧贴圆环下方，不留大段空白）。

### 桌面组件

- 卡片：292 × 260 + 四周 20pt 阴影留白 → 窗口 332 × 300。
- 100pt 整体圆环 + 34pt 上午/下午小圆环。
- 玻璃材质/深色浅色自适应。

---

## 5. 构建 / 运行 / 验证

```bash
cd /Users/liyefei/workspace/workday-widget
./build.sh
open WorkdayWidget.app

# 生成预览
./build.sh --preview

# 计算校验
./WorkdayWidget.app/Contents/MacOS/WorkdayWidget --dump --at 15:00
./WorkdayWidget.app/Contents/MacOS/WorkdayWidget --dump --at 23:59
./WorkdayWidget.app/Contents/MacOS/WorkdayWidget --dump --at 00:30

# 渲染灵动岛预览
./WorkdayWidget.app/Contents/MacOS/WorkdayWidget --render out.png --at 15:00 --island
./WorkdayWidget.app/Contents/MacOS/WorkdayWidget --render out.png --at 15:00 --island --compact
```

工具链注意：

- 本机 `xcode-select` 指向 Command Line Tools，其 SDK（MacOSX27.0）与自带 Swift 6.1.2 不匹配，直接用 `swiftc` 会失败。
- `build.sh` 会自动设置 `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer`。
- 目标：macOS 14+；当前机器 macOS 26.6，Xcode 26.3，Swift 6.2.4。

---

## 6. 验收清单

### 灵动岛

- [x] 正常态被硬件刘海完全遮盖，坐标与 `realNotchRect` 一致（`--dump-island` 验证）。
- [x] 窗口顶边贴屏幕物理顶边，不在菜单栏下方。
- [x] 按刘海实际中心对齐，刘海两侧不露黑边。
- [x] 悬停刘海时同一个黑色形状向下生长，详情在形状内部被揭开。
- [x] 详情被 `clipShape` 裁切，形状外无可见内容。
- [x] 移开鼠标后形状收回刘海内。
- [x] 展开 / 收起期间窗口不 resize（固定 386 × 186）。
- [x] 点击展开后的岛体可固定 / 取消固定。
- [x] 不抢焦点、不激活应用；层级 `mainMenu + 3`，可盖住菜单栏。
- [x] 屏幕参数变化时重新定位；无刘海显示器退化为顶部胶囊。
- [x] 页脚紧贴圆环下方，无多余留白。

### 其他

- [ ] 桌面组件贴桌面层级，可拖动，位置持久化。
- [ ] 三个百分比均为已完成进度，计算正确。
- [ ] 19:30 后显示已加班时长，0 点重置。
- [ ] 周末显示休息状态。
- [ ] 设置项生效并持久化。
- [ ] 菜单栏显示进度环 + 百分比，菜单可显示/隐藏组件、设置、退出。

---

## 7. 交接文件

```
workday-widget/
├── HANDOFF.md                 # 本文档
├── README.md
├── build.sh
├── Resources/Info.plist
├── Sources/
│   ├── main.swift             # 入口、CLI
│   ├── AppDelegate.swift      # 窗口/菜单栏/定时刷新
│   ├── Model.swift            # 时间设置、排班计算、快照
│   ├── DesignSystem.swift     # 颜色、圆环、玻璃背景
│   ├── WidgetView.swift       # 桌面组件 UI
│   ├── IslandView.swift       # 灵动岛 UI（重点修改）
│   ├── SettingsView.swift
│   └── Notifications.swift
└── preview/
    ├── target-normal.png      # 用户提供的正常态参考图
    ├── widget.png
    ├── widget-light.png
    ├── widget-overtime.png
    ├── weekend.png
    ├── island.png
    ├── island-compact.png
    └── island-overtime.png
```

如有歧义，优先按用户原话和 `preview/target-normal.png` 为准，并在真实应用中悬停验证，而不是只看静态预览。
