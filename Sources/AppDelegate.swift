import AppKit
import SwiftUI
import Combine
import QuartzCore

/// Borderless windows need this override to accept clicks / drags.
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The island panel has a fixed window size so SwiftUI can animate the island
/// without resizing the window. Transparent areas must not swallow clicks, so
/// hit testing is limited to the currently visible island body.
final class IslandContainerView: NSView {
    var interactiveRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// Tracks whether the pointer is over the island.
///
/// SwiftUI's `onHover` is not reliable here: while collapsed the island lives
/// underneath the hardware notch, which does not deliver ordinary
/// mouse-entered/exited events to the window below it. Watching the pointer
/// location directly works in both states.
final class IslandHoverTracker {
    var hoverRect: (() -> NSRect?)?
    var onChange: ((Bool) -> Void)?

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var isInside = false

    func start() {
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]

        let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: events,
            handler: { [weak self] _ in self?.evaluate() }
        )
        if let globalMonitor {
            monitors.append(globalMonitor)
        }

        let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: events,
            handler: { [weak self] event in
                self?.evaluate()
                return event
            }
        )
        if let localMonitor {
            monitors.append(localMonitor)
        }

        // Safety net: mouse-moved events stop arriving if the pointer leaves via
        // a Space switch or another app grabs the event stream.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Force a re-read, e.g. after the island resizes or the screen changes.
    func refresh() {
        evaluate()
    }

    private func evaluate() {
        let inside = hoverRect?().map { $0.contains(NSEvent.mouseLocation) } ?? false
        guard inside != isInside else { return }
        isInside = inside
        onChange?(inside)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = WorkdayModel()
    let workLog = WorkLog()
    let islandState = IslandState()

    private enum Layout {
        static let cardWidth: CGFloat = 292
        static let cardHeight: CGFloat = 260
        static let cardPadding: CGFloat = 20
    }

    private var desktopWindow: NSWindow?
    private var islandPanel: NSPanel?
    private var islandContainer: IslandContainerView?
    private var islandHosting: NSHostingView<AnyView>?
    private let islandHover = IslandHoverTracker()
    private var islandMetrics = IslandMetrics(hasNotch: false, notchWidth: 190, notchHeight: 32)
    private var settingsWindow: NSWindow?
    private var statsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var tickTimer: Timer?
    private var lastReconciledMinute = -1
    private var cancellables = Set<AnyCancellable>()
    private var notificationTokens: [NSObjectProtocol] = []

    private var lastStatusTitle = ""
    private var lastStatusPercent = -1

    // MARK: - Hosting helper

    /// Wraps a SwiftUI view in a plain NSView container. Using NSHostingView
    /// directly as the window's contentView lets Auto Layout pin the window to
    /// the content's intrinsic size, which prevents programmatic resizing.
    private func makeHostingContainer<Content: View>(
        rootView: Content,
        size: CGSize
    ) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)

        return container
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupDesktopWindow()
        setupIsland()
        setupBindings()
        registerNotifications()
        startTicking()
        startWorkLog()

        if CommandLine.arguments.contains("--show-stats") {
            DispatchQueue.main.async { [weak self] in
                self?.showStatsWindow()
            }
        }

        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in
                self?.showSettingsWindow()
            }
        }

        if CommandLine.arguments.contains("--expand-island") {
            DispatchQueue.main.async { [weak self] in
                self?.islandState.togglePinned()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        islandHover.stop()
        workLog.stopObserving()
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
    }

    // MARK: - Desktop widget

    private func setupDesktopWindow() {
        let size = CGSize(
            width: Layout.cardWidth + Layout.cardPadding * 2,
            height: Layout.cardHeight + Layout.cardPadding * 2
        )

        let window = WidgetWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true

        window.contentView = makeHostingContainer(
            rootView: WidgetWindowRoot(model: model),
            size: size
        )

        let autosaveName = "WorkdayDesktopWidgetFrame"
        let restored = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)

        let isOnSomeScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if !restored || !isOnSomeScreen {
            placeDesktopWindowAtDefault(window)
        }

        if model.settings.showDesktopWidget {
            window.orderFrontRegardless()
        }
        desktopWindow = window
    }

    private func placeDesktopWindowAtDefault(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        window.setFrameOrigin(
            NSPoint(
                x: visible.maxX - window.frame.width - margin,
                y: visible.maxY - window.frame.height - margin
            )
        )
    }

    // MARK: - Dynamic Island panel

    /// The island belongs on the screen that has a notch, so the collapsed
    /// state can hide underneath it. Falls back to the active screen.
    private func islandScreen() -> NSScreen? {
        if let notched = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func setupIsland() {
        guard let screen = islandScreen() else { return }
        islandMetrics = IslandMetrics(screen: screen)

        let windowSize = IslandLayout.windowSize(islandMetrics)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // NOTE: `isFloatingPanel` resets the window level, so set it first and
        // apply the final level afterwards. The level must sit above the menu
        // bar so the island can occupy the notch and overlap the menu bar.
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false

        let container = IslandContainerView(frame: NSRect(origin: .zero, size: windowSize))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: islandRootView())
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)

        panel.contentView = container
        islandContainer = container
        islandHosting = hosting
        islandPanel = panel

        positionIsland()
        startIslandHoverTracking()
    }

    private func islandRootView() -> AnyView {
        AnyView(
            IslandRoot(model: model, state: islandState, metrics: islandMetrics)
                .environment(\.colorScheme, .dark)
        )
    }

    /// Pins the fixed-size panel so the island's top edge is flush with the
    /// screen's physical top edge — level with the notch, not below the menu bar.
    private func positionIsland() {
        guard let panel = islandPanel, let screen = islandScreen() else { return }

        let metrics = IslandMetrics(screen: screen)
        if metrics != islandMetrics {
            islandMetrics = metrics
            islandHosting?.rootView = islandRootView()
        }

        let size = IslandLayout.windowSize(islandMetrics)
        let centerX = screen.frame.midX + islandMetrics.centerOffset
        let frame = NSRect(
            x: centerX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        islandContainer?.frame = NSRect(origin: .zero, size: size)
        islandHosting?.frame = NSRect(origin: .zero, size: size)

        updateIslandHitRect(expanded: islandState.expanded)

        if model.settings.showIsland {
            panel.orderFrontRegardless()
        }
        islandHover.refresh()
    }

    private func updateIslandHitRect(expanded: Bool) {
        islandContainer?.interactiveRect = IslandLayout.islandRect(
            expanded: expanded,
            metrics: islandMetrics
        )
    }

    /// The island's body in screen coordinates, used for hover detection.
    private func islandHoverRect() -> NSRect? {
        guard model.settings.showIsland,
              let screen = islandPanel?.screen ?? islandScreen() else { return nil }

        let expanded = islandState.expanded
        let size = expanded
            ? IslandLayout.expandedSize(islandMetrics)
            : IslandLayout.collapsedSize(islandMetrics)

        // While collapsed the whole notch is the grab area. While expanded the
        // shape's thin side flares are excluded — they sit under the menu bar,
        // where hovering should not count as being on the island.
        let hoverWidth = expanded ? size.width - 2 * IslandLayout.flare : size.width
        let pad = IslandLayout.hoverPadding
        let centerX = screen.frame.midX + islandMetrics.centerOffset

        return NSRect(
            x: centerX - hoverWidth / 2,
            y: screen.frame.maxY - size.height - pad,
            width: hoverWidth,
            height: size.height + pad
        )
    }

    private func startIslandHoverTracking() {
        islandHover.hoverRect = { [weak self] in self?.islandHoverRect() }
        islandHover.onChange = { [weak self] inside in
            self?.islandState.setHovering(inside)
        }
        islandHover.start()
    }

    private func handleIslandExpansion(_ expanded: Bool) {
        // The window keeps its size; only the SwiftUI island animates. Update
        // the click/hover geometry to match the new state.
        updateIslandHitRect(expanded: expanded)
        islandHover.refresh()
    }

    // MARK: - Bindings

    private func setupBindings() {
        model.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.applyVisibility(settings)
                self.updateStatusItem()
            }
            .store(in: &cancellables)

        islandState.$expanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                self?.handleIslandExpansion(expanded)
            }
            .store(in: &cancellables)
    }

    private func applyVisibility(_ settings: WorkdaySettings) {
        if settings.showDesktopWidget {
            desktopWindow?.orderFrontRegardless()
        } else {
            desktopWindow?.orderOut(nil)
        }

        if settings.showIsland {
            positionIsland()
            islandPanel?.orderFrontRegardless()
        } else {
            islandState.unpin()
            islandState.setHovering(false)
            islandPanel?.orderOut(nil)
        }
    }

    // MARK: - Clock

    private func startTicking() {
        model.now = Date()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.now = Date()
            self.updateStatusItem()
            self.reconcileWorkLogIfNeeded()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        updateStatusItem()
    }

    // MARK: - Work log

    private func startWorkLog() {
        workLog.startObserving { [weak self] in
            self?.model.settings ?? .default
        }
        workLog.reconcile(now: Date(), settings: model.settings)
        lastReconciledMinute = TimeFormat.minutes(from: Date())
    }

    /// Settling a day is cheap, but running it every second is pointless —
    /// once a minute is enough to catch the scheduled start of the workday.
    private func reconcileWorkLogIfNeeded() {
        let minute = TimeFormat.minutes(from: Date())
        guard minute != lastReconciledMinute else { return }
        lastReconciledMinute = minute
        workLog.reconcile(now: Date(), settings: model.settings)
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let desktopItem = NSMenuItem(
            title: "显示桌面组件",
            action: #selector(toggleDesktopWidget),
            keyEquivalent: ""
        )
        desktopItem.tag = 101
        desktopItem.target = self
        menu.addItem(desktopItem)

        let islandItem = NSMenuItem(
            title: "显示灵动岛",
            action: #selector(toggleIsland),
            keyEquivalent: ""
        )
        islandItem.tag = 102
        islandItem.target = self
        menu.addItem(islandItem)

        menu.addItem(.separator())

        let statsItem = NSMenuItem(
            title: "工作时间统计…",
            action: #selector(openStats),
            keyEquivalent: "t"
        )
        statsItem.target = self
        menu.addItem(statsItem)

        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let creditItem = NSMenuItem(
            title: "\(AppInfo.displayName) \(AppInfo.version) · 作者 \(AppInfo.author)",
            action: nil,
            keyEquivalent: ""
        )
        creditItem.isEnabled = false
        menu.addItem(creditItem)

        let quitItem = NSMenuItem(
            title: "退出工作日",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.item(withTag: 101)?.state = model.settings.showDesktopWidget ? .on : .off
        menu.item(withTag: 102)?.state = model.settings.showIsland ? .on : .off
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let snap = model.snapshot
        let title = snap.isWorkday ? "\(snap.percentOverall)%" : "休息"

        if title != lastStatusTitle || snap.percentOverall != lastStatusPercent {
            button.title = title
            button.image = statusRingImage(progress: snap.isWorkday ? snap.overallProgress : 0)
            lastStatusTitle = title
            lastStatusPercent = snap.percentOverall
        }
    }

    /// Small template ring for the menu bar (the system tints it).
    private func statusRingImage(progress: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 1.6
            let trackRect = NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            let track = NSBezierPath(ovalIn: trackRect)
            track.lineWidth = 2.4
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()

            let value = progress.clamped(to: 0...1)
            if value > 0.001 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - 360 * value,
                    clockwise: true
                )
                arc.lineWidth = 2.4
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Settings window

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 740),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "工作日设置"
            window.isReleasedWhenClosed = false
            window.contentView = makeHostingContainer(
                rootView: SettingsView(model: model),
                size: NSSize(width: 420, height: 740)
            )
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Statistics window

    private func showStatsWindow() {
        if statsWindow == nil {
            let size = NSSize(width: 540, height: 660)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "工作时间统计"
            window.isReleasedWhenClosed = false
            window.contentView = makeHostingContainer(
                rootView: StatsView(model: model, log: workLog),
                size: size
            )
            window.center()
            statsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        statsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let center = NotificationCenter.default

        notificationTokens.append(
            center.addObserver(
                forName: .workdayOpenSettings,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showSettingsWindow()
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: .workdayOpenStats,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showStatsWindow()
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: .workdayToggleDesktop,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.model.settings.showDesktopWidget.toggle()
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: .workdayToggleIsland,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.model.settings.showIsland.toggle()
            }
        )

        notificationTokens.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.positionIsland()
            }
        )
    }

    // MARK: - Actions

    @objc private func toggleDesktopWidget() {
        model.settings.showDesktopWidget.toggle()
    }

    @objc private func toggleIsland() {
        model.settings.showIsland.toggle()
    }

    @objc private func openSettings() {
        showSettingsWindow()
    }

    @objc private func openStats() {
        showStatsWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
