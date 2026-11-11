import AppKit
import DayOrderCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private let panel = CalendarPanel()
    private var model: CalendarModel?
    private var launchAtLogin = LaunchAtLogin()
    private var appUpdater = AppUpdater(enabled: false)
    #if DEBUG
    private var smokeLoginService: SmokeLoginService?
    private var smokeCalendarSource: SmokeCalendarSource?
    #endif
    private var refreshTimer: Timer?
    private var isTerminating = false
    private var keyboardMonitor: Any?
    private var hostingController: NSHostingController<AnyView>?
    private var presentationController: CalendarPresentationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        appUpdater = AppUpdater(enabled: smokeDirectory == nil)
        #else
        appUpdater = AppUpdater()
        #endif
        do {
            #if DEBUG
            let smokeDomain = smokeDirectory.map { _ in "com.dayorder.smoke.\(UUID().uuidString)" }
            if let smokeDomain { defaults = UserDefaults(suiteName: smokeDomain)! }
            if smokeDirectory != nil, ProcessInfo.processInfo.arguments.contains("--updates-smoke") {
                guard let path = ProcessInfo.processInfo.environment["DAYORDER_UPDATE_TEST_BUNDLE"],
                      let bundle = Bundle(path: path),
                      bundle.bundleIdentifier?.hasPrefix("com.dayorder.update-test.") == true else {
                    throw CocoaError(.coderInvalidValue)
                }
                UserDefaults(suiteName: bundle.bundleIdentifier!)?.set(Date(), forKey: "SULastCheckTime")
                appUpdater = AppUpdater(bundle: bundle)
            }
            let holidayCacheDirectory = smokeDirectory?.appendingPathComponent("holiday-cache", isDirectory: true)
            if smokeDirectory != nil {
                let service = SmokeLoginService()
                smokeLoginService = service
                launchAtLogin = service.makeController()
            }
            #else
            let holidayCacheDirectory: URL? = nil
            #endif
            let eventSource: any SystemCalendarSource
            #if DEBUG
            if smokeDirectory != nil {
                let source = SmokeCalendarSource()
                smokeCalendarSource = source
                eventSource = source
            } else { eventSource = EventKitCalendarSource() }
            #else
            eventSource = EventKitCalendarSource()
            #endif
            let model = CalendarModel(engine: try CalendarEngine(), holidayCacheDirectory: holidayCacheDirectory,
                                      events: SystemCalendarEvents(defaults: defaults, source: eventSource))
            self.model = model
            let view = CalendarView(model: model, events: model.events, launchAtLogin: launchAtLogin, appUpdater: appUpdater,
                                    updateMenuBar: { [weak self] in self?.refresh() },
                                    updatePanelAppearance: { [weak self] in self?.panel.appearance = $0 }) {
                [weak self] in self?.panel.performClose(nil)
            }
            var root = AnyView(view)
            #if DEBUG
            if let directory = smokeDirectory, let domain = smokeDomain {
                root = AnyView(view.defaultAppStorage(defaults))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.runSmokeTest(directory: directory, defaults: defaults, domain: domain)
                }
            }
            #endif
            // 新内容可能先于窗口增高完成布局，始终从顶部排布，避免临时居中。
            let host = CalendarHostingController(rootView: AnyView(root.frame(minHeight: 0, maxHeight: .infinity, alignment: .top)))
            hostingController = host
            let presentation = CalendarPresentationController(host: host, model: model, defaults: defaults)
            presentationController = presentation
            panel.contentViewController = presentation
            panel.behavior = .transient
            panel.onShow = { [weak self] in self?.panelDidShow() }
            panel.onClose = { [weak self] in self?.panelDidClose() }
            presentation.contentSizeChanged = { [weak self] size in self?.panel.resizeContent(to: size) }

            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            item.button?.target = self
            item.button?.action = #selector(togglePanel)
            item.button?.setAccessibilityLabel("日序日历")
            refresh()

            refreshTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(refresh),
                                                userInfo: nil, repeats: true)
            refreshTimer?.tolerance = 5
            for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                         NSNotification.Name("NSSystemClockDidChangeNotification")] {
                NotificationCenter.default.addObserver(self, selector: #selector(refreshAfterNotification), name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAfterNotification),
                                                              name: NSWorkspace.didWakeNotification, object: nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "日序无法读取日历数据"
            alert.informativeText = "请重新构建或安装完整应用。\n\(error.localizedDescription)"
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    // 系统跨日通知可能在后台线程同步投递；进入主执行器前不能访问界面或模型。
    @objc nonisolated private func refreshAfterNotification() {
        Task { @MainActor [weak self] in
            guard let self, !self.isTerminating else { return }
            self.refresh()
        }
    }

    @objc private func refresh() {
        guard let model else { return }
        model.refreshToday()
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let model, let button = statusItem?.button else { return }
        let day = model.engine.info(for: model.today)
        let display = MenuBarDisplay(rawValue: defaults.string(forKey: "menuBarDisplay") ?? "") ?? .iconAndDate
        let format = MenuBarDateFormat(rawValue: defaults.string(forKey: "menuBarDateFormat") ?? "") ?? .monthDayWeekday
        button.title = display == .iconOnly ? "" : (display == .iconAndDate ? "  " : "") + format.title(for: day)
        button.image = display == .dateOnly ? nil : MenuBarIcon.calendar(day: day.day)
        button.imagePosition = display == .iconOnly ? .imageOnly : .imageLeading
        let fullDate = MenuBarDateFormat.yearMonthDayWeekday.title(for: day)
        button.toolTip = "日序 · \(fullDate) · \(day.lunarFull)"
        button.setAccessibilityLabel("日序日历，" + fullDate)
    }

    @objc private func togglePanel() {
        if panel.isShown {
            panel.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        refresh()
        model?.showingSettings = false
        model?.yearDraft = ""
        model?.goToToday()
        NSApp.activate(ignoringOtherApps: true)
        panel.show(anchoredTo: button)
        panel.contentViewController?.view.window?.makeKey()
    }

    private func panelDidShow() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.panel.isShown, let model = self.model,
                      event.window == self.panel.contentViewController?.view.window else { return false }
                if event.keyCode == 53 {
                    if model.showingSettings { model.showingSettings = false }
                    else if model.showingYearOverview { model.dismissYearLevel() }
                    else if model.agenda != nil { model.closeAgenda() }
                    else { self.panel.performClose(nil) }
                    return true
                }
                guard !model.showingSettings, !model.showingYearOverview,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
                switch event.keyCode {
                case 123: model.moveDay(-1)
                case 124: model.moveDay(1)
                case 125: model.moveDay(7)
                case 126: model.moveDay(-7)
                case 116: model.moveMonth(-1)
                case 121: model.moveMonth(1)
                case 115: model.goToToday()
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func panelDidClose() {
        model?.closeAgenda()
        presentationController?.cancelTransition()
        removeKeyboardMonitor()
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        panel.close()
        presentationController?.cancelTransition()
        model?.cancelHolidayUpdate()
        model?.events.stop()
        refreshTimer?.invalidate()
        removeKeyboardMonitor()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    #if DEBUG
    private var smokeDirectory: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--smoke-test"), args.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    private func runSmokeTest(directory: URL, defaults: UserDefaults, domain: String) async {
        defer { defaults.removePersistentDomain(forName: domain) }
        // 快照主动设置日期；定时刷新不能在较长回归中覆盖测试时钟。
        refreshTimer?.invalidate()
        refreshTimer = nil
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let model else { throw CocoaError(.coderInvalidValue) }
            if ProcessInfo.processInfo.arguments.contains("--refresh-notifications-smoke") {
                try await verifyRefreshNotifications()
                try "主线程及后台线程的跨日、时区、时钟与唤醒通知刷新验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            model.today = model.engine.date(2026, 10, 23)
            model.select(model.today)
            defaults.set("light", forKey: "appearance")
            showPanel()
            // 合成输入阶段不能因自动化宿主抢焦点而关闭弹窗。
            panel.behavior = .applicationDefined
            // showPanel 会刷新真实日期；快照随后固定时钟，使用同一生产视图。
            model.today = model.engine.date(2026, 10, 23)
            model.select(model.today)
            if ProcessInfo.processInfo.arguments.contains("--refresh-rate-smoke") {
                guard let presentation = presentationController, let root = hostingController?.view else {
                    throw CocoaError(.coderInvalidValue)
                }
                try await CalendarRefreshSmoke.verify(model: model, defaults: defaults, root: root,
                    presentation: presentation, directory: directory,
                    close: { self.panel.close() }, reopen: { self.showPanel() })
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-agenda-performance-smoke") {
                guard let source = smokeCalendarSource, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
                defaults.set(1, forKey: "firstWeekday")
                try await CalendarAgendaPerformanceSmoke.verify(model: model, presentation: presentation,
                    source: source, directory: directory)
                try "当天日程滚动性能检查通过。\n".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-agenda-wheel-smoke") {
                guard let source = smokeCalendarSource, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
                defaults.set(1, forKey: "firstWeekday")
                try await CalendarAgendaWheelSmoke.verify(model: model, presentation: presentation,
                    source: source, directory: directory)
                try "日程展开滚轮路由检查通过。\n".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            let agendaContentOnly = ProcessInfo.processInfo.arguments.contains("--calendar-agenda-content-smoke")
            if agendaContentOnly || ProcessInfo.processInfo.arguments.contains("--calendar-agenda-smoke") {
                guard let source = smokeCalendarSource, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
                defaults.set(1, forKey: "firstWeekday")
                if !agendaContentOnly {
                    try await CalendarAgendaNavigationSmoke.verify(model: model, presentation: presentation,
                        source: source, directory: directory,
                        close: { self.panel.close() }, reopen: { self.showPanel() })
                }
                try await CalendarAgendaSmoke.verify(model: model, presentation: presentation, source: source,
                    defaults: defaults, directory: directory) { view, name in
                    try self.saveViewSnapshot(view, name: name, to: directory)
                }
                try "当天日程展开、内部滚动、日期切换及隐藏边界检查通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-mode-latency-smoke") {
                guard let source = smokeCalendarSource, let presentation = presentationController else {
                    throw CocoaError(.coderInvalidValue)
                }
                defaults.set(1, forKey: "firstWeekday")
                try await CalendarModeLatencySmoke.verify(model: model, presentation: presentation,
                    source: source, defaults: defaults, directory: directory)
                try "切档批量采样、启动耗时、异步标记更新和年概览交接检查通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-marker-morph-smoke") {
                guard let source = smokeCalendarSource, let presentation = presentationController else {
                    throw CocoaError(.coderInvalidValue)
                }
                defaults.set(1, forKey: "firstWeekday")
                try await CalendarMarkerMorphSmoke.verify(model: model, presentation: presentation,
                    source: source, defaults: defaults, directory: directory) { view, name in
                        try self.saveViewSnapshot(view, name: name, to: directory)
                    }
                try "日程胶囊、横线、圆点连续形变、淡出、快速接续和实际像素绘制检查通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-mode-animation-smoke") {
                guard let source = smokeCalendarSource, let presentation = presentationController else {
                    throw CocoaError(.coderInvalidValue)
                }
                defaults.set(1, forKey: "firstWeekday")
                try await CalendarModeAnimationSmoke.verify(model: model, presentation: presentation, panel: panel,
                    source: source, defaults: defaults, directory: directory, reopen: { self.showPanel() }) { view, name in
                        try self.saveViewSnapshot(view, name: name, to: directory)
                    }
                try "四档非线性缩放、日期连续绘制、重定向、设置交接、取消和减少动态效果检查通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-mode-smoke") {
                guard let source = smokeCalendarSource, let root = hostingController?.view else {
                    throw CocoaError(.coderInvalidValue)
                }
                model.today = model.engine.date(2026, 11, 5)
                model.select(model.today)
                try await Task.sleep(for: .milliseconds(100))
                try await CalendarModeSmoke.verify(events: model.events, source: source, engine: model.engine, root: root) {
                    try await self.saveSnapshot($0, to: directory)
                }
                try "四档按钮循环、权限检测与请求、隐藏跳过权限和迟到结果检查通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-events-smoke") {
                try await verifyCalendarEvents(directory: directory)
                try "系统日历权限边界、四档显示、固定布局、跨日数据、刷新与迟到结果验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--updates-smoke") {
                try await verifyAppUpdates(directory: directory)
                try "更新偏好、真实设置控件和 Sparkle 检查验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--panel-position-smoke") {
                try await verifyPanelPosition(directory: directory)
                try "面板切月、日期详情与月年过渡的顶部定位验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--panel-smoke") {
                try await verifyPanel(directory: directory)
                try "无箭头面板、尺寸锚定、内外点击、Esc、重复开关与关闭清理验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--settings-transition-smoke") {
                try await verifySettingsTransition(directory: directory)
                try "设置过渡的容器形变、固定弹窗高度、常驻上下栏与背景、取消和减少动态效果验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--settings-smoke") {
                try await verifySettingsDesign(directory: directory)
                try "设置页深浅色与材质、固定布局、滚动、偏好切换和返回验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-grid-smoke") {
                try await verifyCalendarGrid(directory: directory)
                try "真实页面的受控时间绘制验证通过；此检查不验证显示刷新驱动或物理帧率。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--calendar-zoom-smoke") {
                try await verifyCalendarZoom(directory: directory)
                try "月年过渡的常驻上下栏与背景、日期位移、容器尺寸、反向展开、取消和减少动态效果验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--scroll-benchmark") {
                try await benchmarkOverviewScroll(directory: directory)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--year-overview-smoke") {
                try await verifyYearOverview(directory: directory)
                try "年概览滚动、年份跳转、月份选择、输入取消、边界与圆角外观快照验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--month-navigation-smoke") {
                try await verifyMonthNavigationMotion(directory: directory)
                try "月份箭头的非线性位移、连续导航、取消与边界验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--today-scroll-smoke") {
                try await verifyTodayScroll(directory: directory)
                try "返回今天的连续位移、终点与取消验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--month-snap-smoke") {
                defaults.set(1, forKey: "firstWeekday")
                model.today = model.engine.date(2026, 10, 29)
                model.select(model.engine.date(2026, 10, 27))
                for blur in [false, true] {
                    defaults.set(blur, forKey: "blurEnabled")
                    for appearance in ["light", "dark"] {
                        defaults.set(appearance, forKey: "appearance")
                        try await saveSnapshot("rounded-\(blur ? "blur" : "solid")-\(appearance)", to: directory)
                    }
                }
                try await verifyMonthSnapping(directory: directory)
                try "月初吸附、惯性等待、中途取消、四至六周完整显示、返回恢复与边界验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            try await verifyPanel(directory: directory)
            try await verifyCalendarEvents(directory: directory)
            model.today = model.engine.date(2026, 10, 23)
            model.select(model.today)
            try await saveSnapshot("light-october", to: directory)
            defaults.set(1, forKey: "firstWeekday")
            model.today = model.engine.date(2026, 10, 24)
            model.select(model.today)
            try await saveSnapshot("rounded-calendar-design", to: directory)
            try await verifyMonthNavigation(directory: directory)
            model.today = model.engine.date(2026, 10, 23)
            model.select(model.today)
            for appearance in ["light", "dark"] {
                defaults.set(appearance, forKey: "appearance")
                defaults.set(2, forKey: "firstWeekday")
                for (month, day, name) in [(12, 1, "aids"), (12, 3, "disability"), (3, 24, "six-weeks")] {
                    model.select(model.engine.date(2026, month, day))
                    try await saveSnapshot("selection-label-\(name)-\(appearance)", to: directory)
                }
            }
            defaults.set("light", forKey: "appearance")
            model.select(model.today)
            try await verifyCalendarTimeline(directory: directory)
            defaults.set("dark", forKey: "appearance")
            try await saveSnapshot("summary-frost-dark", to: directory)
            defaults.set("light", forKey: "appearance")
            defaults.set(false, forKey: "showSolarTerms")
            try await saveSnapshot("summary-solar-hidden", to: directory)
            defaults.set(true, forKey: "showSolarTerms")
            model.select(model.engine.date(2026, 10, 22))
            try await saveSnapshot("summary-ordinary-day", to: directory)
            model.select(model.engine.date(2026, 4, 5))
            try await saveSnapshot("summary-qingming", to: directory)
            model.select(model.today)
            try await verifyYearOverview(directory: directory)
            defaults.set("dark", forKey: "appearance")
            model.select(model.engine.date(2026, 10, 31))
            try await saveSnapshot("dark-october", to: directory)
            model.select(model.engine.date(2026, 3, 31))
            try await saveSnapshot("six-weeks", to: directory)
            defaults.set("light", forKey: "appearance")
            model.select(model.engine.date(2027, 1, 1))
            try await saveSnapshot("civil-new-year", to: directory)
            model.select(model.engine.date(2026, 5, 1))
            try await saveSnapshot("civil-labour-day", to: directory)
            defaults.set(false, forKey: "showCivil")
            try await saveSnapshot("civil-hidden", to: directory)
            defaults.set(true, forKey: "showCivil")
            model.select(model.engine.date(2020, 10, 1))
            try await saveSnapshot("civil-collision", to: directory)
            model.select(model.engine.date(2026, 12, 1))
            try await saveSnapshot("world-aids-day", to: directory)
            defaults.set(false, forKey: "showWorldDays")
            try await saveSnapshot("world-hidden", to: directory)
            defaults.set(true, forKey: "showWorldDays")
            model.select(model.engine.date(2026, 6, 5))
            try await saveSnapshot("world-solar-collision", to: directory)
            defaults.set(false, forKey: "showWorldDays")
            try await saveSnapshot("world-solar-fallback", to: directory)
            defaults.set(true, forKey: "showWorldDays")
            model.select(model.engine.date(2026, 4, 23))
            try await saveSnapshot("world-long-title", to: directory)
            defaults.set("dark", forKey: "appearance")
            model.select(model.engine.date(2026, 12, 1))
            try await saveSnapshot("world-dark", to: directory)
            defaults.set("light", forKey: "appearance")
            model.showingSettings = true
            try await saveSnapshot("settings", to: directory)
            defaults.set("dark", forKey: "appearance")
            try await saveSnapshot("settings-dark", to: directory)
            defaults.set("light", forKey: "appearance")
            try scrollSettings(toBottom: true)
            try await saveSnapshot("settings-bottom", to: directory)
            try scrollSettings(toBottom: false)
            try await verifySettingsDesign(directory: directory)
            try await verifySettingsTransition(directory: directory)
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
            // 无合成输入的偏好与材质回归使用生产弹窗行为，覆盖临时窗口的开关更新。
            panel.behavior = .transient
            try await verifyMenuBar(directory: directory, defaults: defaults, domain: domain)
            try await verifyHolidays(directory: directory)
            if ProcessInfo.processInfo.arguments.contains("--holiday-network-smoke") {
                try await verifyHolidayNetwork(directory: directory)
            }
            model.showingSettings = false
            model.select(model.engine.date(2026, 12, 31))
            model.moveDay(1)
            guard model.selection == model.engine.date(2027, 1, 1) else { throw CocoaError(.coderInvalidValue) }
            model.select(model.engine.date(1901, 1, 1))
            model.moveDay(-1)
            guard model.selection == model.engine.date(1901, 1, 1), !model.canMoveMonth(-1) else {
                throw CocoaError(.coderInvalidValue)
            }
            try await verifyReopen(directory: directory, domain: domain)
            defaults.set(false, forKey: "blurEnabled")
            try await saveSnapshot("blur-off-light", to: directory)
            model.openYearOverview()
            try await saveSnapshot("blur-off-year-light", to: directory)
            defaults.set("dark", forKey: "appearance")
            try await saveSnapshot("blur-off-year-dark", to: directory)
            model.showingYearOverview = false
            try await saveSnapshot("blur-off-dark", to: directory)
            model.showingSettings = true
            try await saveSnapshot("blur-off-settings-dark", to: directory)
            model.showingSettings = false
            defaults.set(true, forKey: "blurEnabled")
            try await saveSnapshot("blur-on-restored-dark", to: directory)
            model.openYearOverview()
            try await saveSnapshot("blur-on-year-dark", to: directory)
            defaults.set("light", forKey: "appearance")
            try await saveSnapshot("blur-on-year-light", to: directory)
            model.showingYearOverview = false
            try await saveSnapshot("blur-on-restored-light", to: directory)
            try await verifyRefreshNotifications()
            panel.performClose(nil)
            guard !panel.isShown, keyboardMonitor == nil else { throw CocoaError(.coderInvalidValue) }
            try "真实状态栏弹窗、连续周滚动与跨月选择、滚动位置恢复、辅助功能动作、外观与节日快照、年概览导航、日期边界、关闭清理通过。\n"
                .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        } catch {
            fputs("日序冒烟验证失败：\(error)\n", stderr)
            exit(1)
        }
    }

    private func verifyRefreshNotifications() async throws {
        guard let model, let button = statusItem?.button else { throw CocoaError(.coderInvalidValue) }
        let notifications: [(NotificationCenter, Notification.Name)] = [
            (.default, .NSCalendarDayChanged),
            (.default, .NSSystemTimeZoneDidChange),
            (.default, Notification.Name("NSSystemClockDidChangeNotification")),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)
        ]
        defaults.set(MenuBarDisplay.dateOnly.rawValue, forKey: "menuBarDisplay")
        defaults.set(MenuBarDateFormat.yearMonthDayWeekday.rawValue, forKey: "menuBarDateFormat")
        defer {
            defaults.removeObject(forKey: "menuBarDisplay")
            defaults.removeObject(forKey: "menuBarDateFormat")
            refresh()
        }
        for (center, name) in notifications {
            for background in [true, false] {
                for followingToday in [true, false] {
                    let today = model.engine.today()
                    let yesterday = model.engine.addingDays(-1, to: today)
                    let browsingDate = model.engine.addingDays(-7, to: today)
                    model.today = yesterday
                    model.select(followingToday ? yesterday : browsingDate)
                    updateStatusItem()
                    if background {
                        await Task.detached {
                            precondition(!Thread.isMainThread)
                            center.post(name: name, object: nil)
                        }.value
                    } else {
                        center.post(name: name, object: nil)
                    }
                    let began = ProcessInfo.processInfo.systemUptime
                    while model.today != today, ProcessInfo.processInfo.systemUptime - began < 2 {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let expectedTitle = MenuBarDateFormat.yearMonthDayWeekday.title(for: model.engine.info(for: today))
                    guard model.today == today,
                          model.selection == (followingToday ? today : browsingDate),
                          button.title == expectedTitle else {
                        fputs("通知刷新未更新日期和菜单栏，或覆盖浏览选择：\(name.rawValue)，后台=\(background)，跟随今天=\(followingToday)\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                }
            }
        }
    }

    private func verifyCalendarEvents(directory: URL) async throws {
        guard let model, let source = smokeCalendarSource, let root = hostingController?.view,
              let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
        let events = model.events
        let savedSelection = model.selection
        let savedToday = model.today
        let savedWeekday = defaults.object(forKey: "firstWeekday")
        let savedAppearance = defaults.object(forKey: "appearance")
        defer {
            events.choose(.hidden)
            defaults.set(savedWeekday, forKey: "firstWeekday")
            defaults.set(savedAppearance, forKey: "appearance")
            model.today = savedToday
            model.select(savedSelection)
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { fputs("日程验证失败：\(message)\n", stderr); throw CocoaError(.coderInvalidValue) }
        }
        func wait(_ condition: () async -> Bool) async throws {
            let end = Date().addingTimeInterval(3)
            while !(await condition()) {
                try require(Date() < end, "异步状态未在期限内收敛")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func settled() async throws {
            try await wait { !events.loading }
            events.permissionSettingsPresented = false
        }
        func choose(_ mode: CalendarEventDisplay) {
            guard let button = descendants(root).compactMap({ $0 as? CalendarEventModeButton }).first else {
                preconditionFailure("未找到真实日程切换按钮")
            }
            // 同档位重试也走真实按钮，完整循环后重新进入目标档。
            for _ in 0..<4 {
                button.performClick(nil)
                if events.mode == mode { break }
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        func fixture(_ id: String, _ title: String, day: Int, color: CalendarEvent.Color,
                     hour: Int = 10, duration: TimeInterval = 3600, allDay: Bool = false, month: Int = 11) -> CalendarEvent {
            let start = local.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
            return CalendarEvent(id: id, title: title, start: start, end: start.addingTimeInterval(duration), allDay: allDay, color: color)
        }
        let blue = CalendarEvent.Color(red: 0.20, green: 0.48, blue: 0.95)
        let purple = CalendarEvent.Color(red: 0.65, green: 0.30, blue: 0.80)
        let values = [fixture("meeting", "周会", day: 5, color: blue),
                      fixture("review", "产品评审与需求讨论", day: 5, color: purple, hour: 14),
                      fixture("third", "复盘", day: 5, color: blue, hour: 16),
                      fixture("dinner", "聚餐", day: 8, color: purple),
                      fixture("birthday", "生日", day: 14, color: blue, hour: 0, duration: 86400, allDay: true),
                      fixture("car", "汽车保养", day: 23, color: purple),
                      fixture("retreat", "团队出行", day: 16, color: blue, hour: 0, duration: 9 * 86400, allDay: true),
                      fixture("trip", "跨日出差", day: 26, color: blue, hour: 23, duration: 7200)]
        defaults.set(1, forKey: "firstWeekday")
        model.today = model.engine.date(2026, 11, 5)
        model.select(model.today)
        events.update(month: model.month, engine: model.engine)
        try require(events.mode == .hidden && events.days.isEmpty, "初始默认必须隐藏")
        let hiddenRevision = events.revision
        events.update(month: model.engine.date(2026, 10, 1), engine: model.engine)
        events.update(month: model.month, engine: model.engine)
        try require(events.revision == hiddenRevision, "隐藏模式的空刷新不应重建日期内容")
        let initialRequests = await source.requests
        try require(await source.reads == 0 && initialRequests == 0, "隐藏状态不得读取或请求授权")
        let readsBeforeDenied = await source.reads
        await source.configure(access: .notDetermined, grant: .denied)
        choose(.detailed)
        try await settled()
        try require(events.authorization == .denied && events.days.isEmpty, "拒绝权限必须清空日程")
        try require(await source.reads == readsBeforeDenied, "拒绝权限后仍调用了读取边界")
        try require(events.statusText.contains("系统设置"), "拒绝后缺少恢复说明")
        for access in [CalendarAuthorization.restricted, .writeOnly] {
            await source.configure(access: access, grant: .denied)
            choose(.compact)
            try await settled()
            try require(events.days.isEmpty && events.authorization != .fullAccess, "受限或仅写权限不能读取")
            try require(await source.reads == readsBeforeDenied, "无完整访问权限时触发了读取")
        }
        await source.configure(access: .notDetermined, values: values, delay: .milliseconds(120))
        let requests = await source.requests
        choose(.detailed)
        try await Task.sleep(for: .milliseconds(20))
        choose(.compact)
        try await settled()
        try require(await source.requests == requests + 1, "快速切换重复请求了授权")
        try require(events.mode == .compact && events.days[model.today]?.count == 3, "授权后未显示按日归属的数据")
        try require(events.days[model.engine.date(2026, 11, 27)]?.first?.title == "跨日出差", "跨日事件丢失")
        let stored = SystemCalendarEvents(defaults: defaults, source: source)
        try require(stored.mode == .compact, "显示偏好未持久化")
        stored.stop()
        var geometry: [[String: Any]] = []
        for month in [2, 8, 10, 11] {
            var monthValues = values.map { value in
                var parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: value.start)
                parts.month = month
                let start = local.date(from: parts)!
                return CalendarEvent(id: value.id, title: value.title, start: start,
                                     end: start.addingTimeInterval(value.end.timeIntervalSince(value.start)),
                                     allDay: value.allDay, color: value.color)
            }
            if month == 10 {
                monthValues += [fixture("holiday", "国庆节（休）", day: 4, color: purple,
                                        hour: 0, duration: 4 * 86400, allDay: true, month: 10),
                                fixture("visit", "拜访", day: 6, color: blue, month: 10)]
            }
            await source.configure(access: .fullAccess, values: monthValues)
            model.select(model.engine.date(2026, month, month == 10 ? 6 : 18))
            try await Task.sleep(for: .milliseconds(100))
            let selection = model.selection
            for mode in CalendarEventDisplay.allCases {
                choose(mode)
                try await settled()
                for appearance in ["light", "dark"] {
                    defaults.set(appearance, forKey: "appearance")
                    try await saveSnapshot("events-\(month)-\(mode.rawValue)-\(appearance)", to: directory)
                    let table = try calendarTimelineTable()
                    let timeline = model.calendarTimeline(firstWeekday: 1)
                    let rows = timeline.weekRows(inMonth: model.month)!
                    let height = rows.reduce(CGFloat.zero) { $0 + table.rect(ofRow: $1).height }
                    try require(abs(height - mode.viewportHeight) < 0.6, "增加行高后月份高度不匹配")
                    try require(abs(table.enclosingScrollView!.contentSize.height - mode.viewportHeight) < 0.6, "日期区高度不匹配")
                    try require(root.bounds.width == 320 && model.selection == selection,
                                "面板宽度或选择被模式切换改变：月份=\(month)，模式=\(mode)，宽度=\(root.bounds.width)，选择=\(model.selection)，预期=\(selection)")
                    let buttons = descendants(table).compactMap { $0 as? CalendarDayButton }.filter { !$0.visibleRect.isEmpty }
                    let seams = try CalendarEventSpanSmoke.verify(buttons: buttons, mode: mode, root: presentation.view,
                        snapshot: directory.appendingPathComponent("events-\(month)-\(mode.rawValue)-\(appearance).png"))
                    do {
                        let button = buttons.first { $0.date == model.engine.date(2026, month, 5) }
                        try require(button != nil, "包含日程的真实日期按钮不可见")
                        try require(mode == .hidden || button?.events.count == (month == 10 ? 4 : 3), "可见日期未收到日程")
                        try require(button?.accessibilityLabel()?.contains("周会") == (mode != .hidden), "隐藏与旁白日程语义不一致")
                    }
                    guard let icon = descendants(root).compactMap({ $0 as? CalendarEventModeButton }).first else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    let frame = root.convert(icon.bounds, from: icon)
                    try require(icon.mode == mode && frame.minX > 120 && frame.maxX < 210, "模式图标未位于月份和今天之间")
                    geometry.append(["month": month, "mode": mode.rawValue, "appearance": appearance,
                                     "viewport": height, "weeks": rows.count, "header": presentation.shell!.header.frame.height,
                                     "width": root.bounds.width, "iconX": frame.minX, "spanSeams": seams])
                }
            }
        }
        await source.configure(access: .fullAccess, values: values, failing: true)
        choose(.detailed)
        try await settled()
        try require(events.errorMessage != nil && events.days.isEmpty, "读取失败缺少明确错误或残留旧数据")
        await source.configure(access: .fullAccess, values: values)
        choose(.detailed)
        try await settled()
        try require(events.errorMessage == nil && !events.days.isEmpty, "读取失败后无法重试恢复")
        await source.holdRead()
        choose(.detailed)
        try await wait { await source.hasHeldRead }
        choose(.hidden)
        await source.finishRead(values)
        try await Task.sleep(for: .milliseconds(50))
        try require(events.days.isEmpty && events.mode == .hidden, "隐藏后的迟到读取恢复了私有数据")
        await source.holdRead()
        choose(.dots)
        try await wait { await source.hasHeldRead }
        await source.configure(access: .denied)
        await source.finishRead(values)
        try await settled()
        try require(events.authorization == .denied && events.days.isEmpty, "读取期间撤销权限后仍展示数据")
        await source.configure(access: .fullAccess, values: values)
        let reads = await source.reads
        await Task.detached { NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil) }.value
        try await wait { await source.reads > reads && !events.loading }
        try require(!events.days.isEmpty, "后台日历变更通知未恢复日程")
        model.showingSettings = true
        try await saveSnapshot("events-settings-preserved", to: directory)
        model.showingSettings = false
        try await waitForCalendarTransition()
        model.openYearOverview()
        try await saveSnapshot("events-year-preserved", to: directory)
        model.dismissYearLevel()
        try await waitForCalendarTransition()
        choose(.hidden)
        try await settled()
        model.today = model.engine.date(2026, 10, 31)
        model.select(model.engine.date(2026, 10, 16))
        defaults.set("light", forKey: "appearance")
        try await saveSnapshot("readme-calendar-light", to: directory)
        try require(model.month == model.engine.date(2026, 10, 1), "同时切换模式与跳转月份时，旧视口覆盖了新导航")
        let readmeTable = try calendarTimelineTable()
        let october = model.calendarTimeline(firstWeekday: 1).weekRows(inMonth: model.month)!.lowerBound
        try require(abs(readmeTable.visibleRect.minY - readmeTable.rect(ofRow: october).minY) < 1,
                    "展示图的月份状态与真实日期视口不一致")
        model.select(model.engine.date(2026, 10, 23))
        defaults.set("dark", forKey: "appearance")
        try await saveSnapshot("readme-calendar-dark", to: directory)
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("events-geometry.json"))
        for month in [2, 8, 9] {
            try await waitForCalendarTransition()
            let output = directory.appendingPathComponent("zoom-\(month)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try await CalendarEventZoomSmoke.verify(model: model, presentation: presentation, source: source,
                defaults: defaults, directory: output, month: month) { view, name in
                    try self.saveViewSnapshot(view, name: name, to: output)
                }
        }
    }

    private func verifyPanelPosition(directory: URL) async throws {
        guard let model, let button = statusItem?.button else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        let selection = model.selection
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior; model.select(selection) }
        var samples: [[String: Any]] = []
        var heights: [CGFloat] = []
        func sample(_ name: String, duration: Double = 0.7) async throws {
            let start = ProcessInfo.processInfo.systemUptime
            var failure: (actual: CGFloat, expected: CGFloat)?
            repeat {
                try await Task.sleep(for: .milliseconds(8))
                guard let statusWindow = button.window else { throw CocoaError(.coderInvalidValue) }
                let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
                let expectedTop = min(anchor.minY, statusWindow.screen?.visibleFrame.maxY ?? anchor.minY) - 6
                let frame = panel.frame
                heights.append(frame.height)
                if abs(frame.maxY - expectedTop) > 1, failure == nil {
                    failure = (frame.maxY, expectedTop)
                }
                samples.append(["scenario": name, "seconds": ProcessInfo.processInfo.systemUptime - start,
                                "top": frame.maxY, "expectedTop": expectedTop, "height": frame.height])
            } while ProcessInfo.processInfo.systemUptime - start < duration
            try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("panel-position.json"))
            if let failure {
                try await saveSnapshot("panel-position-failure", to: directory)
                fputs("面板顶部偏离图标：\(name)，实际=\(failure.actual)，预期=\(failure.expected)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        try await saveSnapshot("panel-position-initial", to: directory)
        try await sample("initial")
        for (month, day) in [(6, 8), (10, 23), (10, 22), (4, 5), (6, 8)] {
            model.select(model.engine.date(2026, month, day))
            try await sample("select-\(month)-\(day)")
        }
        for amount in [-1, -1, 1, 1, 1, -1] {
            model.moveMonth(amount, animated: true)
            try await sample("navigate-\(amount)")
        }
        model.openYearOverview()
        try await sample("year-out")
        try await clickOverviewMonth(year: 2026, month: 6)
        try await sample("year-to-june")
        guard (heights.max() ?? 0) - (heights.min() ?? 0) > 40 else {
            fputs("面板位置检查未覆盖实际高度变化。\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("panel-position-june", to: directory)
    }

    private func verifyPanel(directory: URL) async throws {
        guard let presentation = presentationController, let button = statusItem?.button,
              let statusWindow = button.window else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        defer { panel.behavior = behavior }
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else {
                fputs("面板验证失败：\(message)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        func click(_ window: NSWindow, at point: NSPoint) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    throw CocoaError(.coderInvalidValue)
                }
                NSApp.postEvent(event, atStart: false)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await saveSnapshot("panel-light", to: directory)
        try check(panel.isKeyWindow && panel.styleMask == .borderless, "应为可输入的无边框面板")
        try check(panel.contentSize == presentation.view.bounds.size, "外框不应包含箭头或标题栏区域")
        let top = panel.frame.maxY
        model?.openYearOverview()
        try await saveSnapshot("panel-year", to: directory)
        try check(abs(panel.frame.maxY - top) < 1, "切换年概览时顶部应保持锚定")
        model?.showingYearOverview = false
        defaults.set("dark", forKey: "appearance")
        try await saveSnapshot("panel-dark", to: directory)
        defaults.set("light", forKey: "appearance")
        try await saveSnapshot("panel-restored", to: directory)
        panel.behavior = .transient
        try await click(panel, at: NSPoint(x: 2, y: 2))
        try check(panel.isShown, "点击面板内部不应关闭")
        try await click(statusWindow, at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        try check(!panel.isShown && keyboardMonitor == nil && !panel.hasDismissalMonitors, "再次点击图标应关闭且清理监控")
        for _ in 0..<3 {
            button.performClick(nil)
            try check(panel.isShown && panel.hasDismissalMonitors && keyboardMonitor != nil, "图标应重新打开面板")
            panel.close()
            panel.close()
            try check(!panel.hasDismissalMonitors && keyboardMonitor == nil, "重复关闭必须保持清理完成")
        }
        showPanel()
        try await Task.sleep(for: .milliseconds(100))
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53) else { throw CocoaError(.coderInvalidValue) }
        NSApp.postEvent(escape, atStart: false)
        try await Task.sleep(for: .milliseconds(100))
        try check(!panel.isShown && !panel.hasDismissalMonitors, "Esc 应关闭月历并清理")
        showPanel()
        let outside = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
                               styleMask: .borderless, backing: .buffered, defer: false)
        outside.isReleasedWhenClosed = false
        defer { outside.close() }
        try await click(outside, at: NSPoint(x: 10, y: 10))
        try check(!panel.isShown && keyboardMonitor == nil, "点击其他窗口应关闭面板")
        showPanel()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try check(!panel.isShown && !panel.hasDismissalMonitors, "切换应用应关闭并清理")
        showPanel()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try check(!panel.isShown && !panel.hasDismissalMonitors, "屏幕布局变化应关闭并清理")
        panel.behavior = .applicationDefined
        showPanel()
        try await verifyPanelPosition(directory: directory)
    }

    private func verifyReopen(directory: URL, domain: String) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        let preferences = NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:])
        for screen in ["month", "settings", "year-overview"] {
            model.select(model.engine.date(2048, 12, 23))
            if screen == "settings" { model.showingSettings = true }
            if screen == "year-overview" {
                model.openYearOverview()
                model.yearDraft = "无效年份"
            }
            model.today = model.engine.addingDays(-1, to: model.engine.today())
            panel.performClose(nil)
            togglePanel()
            let today = model.engine.today()
            guard panel.isShown, !model.showingSettings, !model.showingYearOverview,
                  model.yearDraft.isEmpty, model.today == today,
                  model.selection == model.engine.clamped(today),
                  model.month == model.engine.monthStart(model.selection),
                  preferences.isEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:])) else {
                fputs("重新打开未回到今日：\(screen)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        try await saveSnapshot("reopened-today", to: directory)
    }

    private func verifyHolidays(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        model.showingSettings = false
        defaults.set("light", forKey: "appearance")
        model.select(model.engine.date(2026, 10, 1))
        guard model.holidays.day(model.engine.info(for: model.selection))?.isOffDay == true else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("holiday-off-day", to: directory)
        model.select(model.engine.date(2026, 10, 10))
        guard model.holidays.day(model.engine.info(for: model.selection))?.isOffDay == false else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("holiday-work-day", to: directory)
        defaults.set("dark", forKey: "appearance")
        try await saveSnapshot("holiday-dark", to: directory)
        defaults.set(false, forKey: "showHolidaySchedule")
        try await saveSnapshot("holiday-hidden", to: directory)
        defaults.set(true, forKey: "showHolidaySchedule")
        defaults.set("light", forKey: "appearance")
        model.select(model.engine.date(2030, 1, 1))
        try await saveSnapshot("holiday-unknown-year", to: directory)
        model.select(model.engine.date(2026, 12, 31))
        try await saveSnapshot("holiday-unknown-cross-year", to: directory)
        model.select(model.engine.date(2026, 10, 10))
        model.showingSettings = true
        try await saveSnapshot("holiday-settings", to: directory)
        try scrollSettings(toBottom: true)
        try await saveSnapshot("holiday-settings-bottom", to: directory)
    }

    private func verifyHolidayNetwork(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        model.updateHolidays(year: 2026)
        for _ in 0..<450 {
            if model.holidayUpdatingYear == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard model.holidayUpdatingYear == nil,
              model.holidayUpdateMessages[2026]?.contains("2026年已更新") == true else {
            model.cancelHolidayUpdate()
            fputs("放假联网验证失败：\(model.holidayUpdateMessages[2026] ?? "未完成")\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        let repository = HolidayRepository(cacheDirectory: directory.appendingPathComponent("holiday-cache"))
        guard let cached = await repository.cached(year: 2026), cached.days.count == 39 else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("holiday-network-result", to: directory)
        try scrollSettings(toBottom: true)
        try await saveSnapshot("holiday-network-result-bottom", to: directory)
        try "已通过真实 holiday-cn 下载、校验、缓存写入与重新读取。\n"
            .write(to: directory.appendingPathComponent("holiday-network-result.txt"), atomically: true, encoding: .utf8)
    }

    private func verifyYearOverview(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let original = model.selection
        // 自动化宿主可能抢走焦点；键盘验证期间固定浮层，避免外部失焦关闭干扰 Esc 结果。
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        showPanel()
        model.select(original)
        // 先让程序化选择进入真实视口，再模拟用户打开年概览；焦点由可见月份决定。
        let readyBy = Date().addingTimeInterval(3)
        let timeline = model.calendarTimeline(firstWeekday: defaults.integer(forKey: "firstWeekday"))
        let row = timeline.weekRows(inMonth: model.engine.monthStart(original))!.lowerBound
        while true {
            let table = try calendarTimelineTable()
            if model.calendarSnappedMonth == model.engine.monthStart(original),
               abs(table.visibleRect.minY - table.rect(ofRow: row).minY) < 1 { break }
            guard Date() < readyBy else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.openYearOverview()
        guard model.yearDraft == "2026" else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("year-overview", to: directory)
        try assertOverviewVisible(year: 2026, month: 9)
        try await verifyOverviewHover(directory: directory)
        defaults.set(1, forKey: "firstWeekday")
        try await saveSnapshot("year-overview-sunday", to: directory)
        defaults.set(2, forKey: "firstWeekday")
        try scrollOverview(by: 260)
        try await saveSnapshot("year-overview-scrolled", to: directory)
        guard model.selection == original else { throw CocoaError(.coderInvalidValue) }
        model.editOverviewYear(2026)
        model.yearDraft = "2048"
        try await saveSnapshot("year-entry", to: directory)
        guard let window = hostingController?.view.window,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                  isARepeat: false, keyCode: 53) else { throw CocoaError(.coderInvalidValue) }
        NSApp.postEvent(escape, atStart: false)
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard !model.showingYearEntry, model.showingYearOverview, model.selection == original else {
            throw CocoaError(.coderInvalidValue)
        }
        NSApp.postEvent(escape, atStart: false)
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard !model.showingYearOverview, panel.isShown, model.selection == original else {
            fputs("取消验证失败：overview=\(model.showingYearOverview), panel=\(panel.isShown), selection=\(model.selection == original), monitor=\(keyboardMonitor != nil)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        model.openYearOverview()
        model.editOverviewYear(2026)
        model.yearDraft = "2048"
        model.jumpToOverviewYear()
        guard model.overviewTarget == 204801, !model.showingYearEntry, model.selection == original else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("year-jump-result", to: directory)
        try assertOverviewVisible(year: 2048, month: 1)
        try scrollOverview(by: 400)
        model.editOverviewYear(2048)
        model.jumpToOverviewYear()
        try await saveSnapshot("year-jump-repeated", to: directory)
        try assertOverviewVisible(year: 2048, month: 1)
        try await clickOverviewMonth(year: 2048, month: 2)
        guard model.selection == model.engine.date(2048, 2, 23), !model.showingYearOverview else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("month-jump-result", to: directory)
        model.openYearOverview()
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        let monthTable = try overviewTable()
        let januaryRow = (2048 - CalendarEngine.years.lowerBound) * 7 + 1
        guard let pair = monthTable.view(atColumn: 0, row: januaryRow, makeIfNecessary: false),
              let january = pair.subviews.compactMap({ $0 as? NSButton }).first,
              january.accessibilityLabel() == "2048年1月", january.accessibilityRole() == .button,
              january.accessibilityPerformPress() else {
            fputs("年概览月份辅助功能按钮不可用\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard model.selection == model.engine.date(2048, 1, 23), !model.showingYearOverview else {
            fputs("年概览辅助功能动作未选择目标月份\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        model.openYearOverview()
        model.editOverviewYear(2048)
        for invalid in ["", "abc", "1900", "2101"] {
            model.yearDraft = invalid
            let previousTarget = model.overviewTarget
            model.jumpToOverviewYear()
            guard model.validYearDraft == nil, model.overviewTarget == previousTarget,
                  model.showingYearEntry else { throw CocoaError(.coderInvalidValue) }
        }
        try await saveSnapshot("year-entry-invalid", to: directory)
        let beforeInvalidJump = model.selection
        for (year, month) in [(1900, 1), (2101, 1), (2026, 0), (2026, 13)] {
            model.jumpToMonth(month, year: year)
            guard model.selection == beforeInvalidJump, model.showingYearOverview else {
                fputs("无效跳转改变选择：\(year)-\(month)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        for (year, month, day) in [(2024, 2, 29), (2025, 2, 28), (1901, 1, 31), (2100, 12, 31)] {
            model.select(model.engine.date(2026, 1, 31))
            model.jumpToMonth(month, year: year)
            guard model.selection == model.engine.date(year, month, day) else {
                fputs("跳转结果不符：\(year)-\(month)-\(day)，实际 \(model.selection)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        model.openYearOverview()
        defaults.set("dark", forKey: "appearance")
        try await saveSnapshot("year-overview-upper-bound-dark", to: directory)
        model.jumpToMonth(1, year: 1901)
        model.openYearOverview()
        try await saveSnapshot("year-overview-lower-bound-dark", to: directory)
        let today = model.today
        let blurEnabled = defaults.bool(forKey: "blurEnabled")
        model.today = model.engine.date(2026, 10, 24)
        model.select(model.today)
        model.openYearOverview()
        defaults.set(1, forKey: "firstWeekday")
        for blur in [false, true] {
            defaults.set(blur, forKey: "blurEnabled")
            for appearance in ["light", "dark"] {
                defaults.set(appearance, forKey: "appearance")
                try await saveSnapshot("year-rounded-\(blur ? "blur" : "solid")-\(appearance)", to: directory)
                try await saveOverviewMonthFeedback(year: 2026, month: 9,
                    name: "year-month-hover-\(blur ? "blur" : "solid")-\(appearance)", to: directory)
            }
        }
        defaults.set(2, forKey: "firstWeekday")
        defaults.set("light", forKey: "appearance")
        model.select(model.engine.date(2026, 3, 24))
        model.openYearOverview()
        try await saveSnapshot("year-rounded-six-weeks", to: directory)
        try await saveOverviewMonthFeedback(year: 2026, month: 3, name: "year-month-hover-six-weeks", to: directory)
        defaults.set(blurEnabled, forKey: "blurEnabled")
        model.today = today
        model.select(original)
        defaults.set("light", forKey: "appearance")
    }

    private func saveOverviewMonthFeedback(year: Int, month: Int, name: String, to directory: URL) async throws {
        let table = try overviewTable()
        let row = (year - CalendarEngine.years.lowerBound) * 7 + 1 + (month - 1) / 2
        guard let pair = table.view(atColumn: 0, row: row, makeIfNecessary: false),
              let button = pair.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "\(year)年\(month)月" }),
              let window = button.window, let screen = NSScreen.screens.first,
              let cursor = CGEvent(source: nil)?.location else { throw CocoaError(.coderInvalidValue) }
        defer {
            button.highlight(false)
            CGWarpMouseCursorPosition(cursor)
            button.updateTrackingAreas()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let point = window.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: 12), to: nil))
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: screen.frame.maxY - point.y))
        button.updateTrackingAreas()
        try await saveSnapshot(name, to: directory)
        try verifyOverviewCaption(button, month: year * 100 + month, name: name, to: directory)
        button.highlight(true)
        try await saveSnapshot(name + "-pressed", to: directory)
        try verifyOverviewCaption(button, month: year * 100 + month, name: name + "-pressed", to: directory)
    }

    private func verifyOverviewCaption(_ button: NSButton, month: Int, name: String, to directory: URL) throws {
        guard let participant = button as? any CalendarZoomParticipant,
              let caption = participant.zoomCaption(month: month, in: button),
              let image = CalendarSnapshotImage.rasterized(caption.image, scale: 2),
              let bitmap = image.representations.first as? NSBitmapImageRep,
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.coderInvalidValue)
        }
        try png.write(to: directory.appendingPathComponent(name + "-caption.png"))
        // 右侧 4 pt 位于文字之外，必须透明，防止反馈底色在转场中叠加。
        let x = bitmap.pixelsWide - 8
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent < 0.01 else {
                fputs("转场标题快照包含反馈底色：\(name)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        let hasText = (0..<bitmap.pixelsWide).contains { x in
            (0..<bitmap.pixelsHigh).contains { y in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
            }
        }
        guard hasText else {
            fputs("转场标题快照丢失文字：\(name)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func verifyMenuBar(directory: URL, defaults: UserDefaults, domain: String) async throws {
        guard let model, let button = statusItem?.button else { throw CocoaError(.coderInvalidValue) }
        // 通过同一偏好触发 SwiftUI 的 onChange，验证设置确实即时更新状态栏。
        defaults.set(MenuBarDisplay.dateOnly.rawValue, forKey: "menuBarDisplay")
        defaults.set(MenuBarDateFormat.yearMonthDay.rawValue, forKey: "menuBarDateFormat")
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        let today = model.engine.info(for: model.today)
        guard button.title == MenuBarDateFormat.yearMonthDay.title(for: today), button.image == nil else {
            throw CocoaError(.coderInvalidValue)
        }
        try saveViewSnapshot(button, name: "menubar-date-only", to: directory)
        try await saveSnapshot("settings-date-only", to: directory)
        guard UserDefaults(suiteName: domain)?.string(forKey: "menuBarDisplay") == MenuBarDisplay.dateOnly.rawValue,
              UserDefaults(suiteName: domain)?.string(forKey: "menuBarDateFormat") == MenuBarDateFormat.yearMonthDay.rawValue else {
            throw CocoaError(.coderInvalidValue)
        }
        defaults.set(MenuBarDisplay.iconOnly.rawValue, forKey: "menuBarDisplay")
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard button.title.isEmpty, button.image != nil, button.imagePosition == .imageOnly else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("settings-icon-only", to: directory)
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
            button.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
            for day in [1, 9, 10, 23, 31] {
                model.today = model.engine.date(2026, 10, day)
                updateStatusItem()
                try await Task.sleep(for: .milliseconds(100))
                guard button.image?.accessibilityDescription == "\(day)日", button.title.isEmpty else {
                    throw CocoaError(.coderInvalidValue)
                }
                try saveViewSnapshot(button, name: "menubar-\(appearance)-\(day)", to: directory)
            }
        }
        // 选择其他日期不改变图标，刷新今天后图标恢复真实日期。
        model.select(model.engine.date(2027, 1, 1))
        updateStatusItem()
        guard button.image?.accessibilityDescription == "31日" else { throw CocoaError(.coderInvalidValue) }
        refresh()
        guard button.image?.accessibilityDescription == "\(model.engine.info(for: model.today).day)日" else {
            throw CocoaError(.coderInvalidValue)
        }
        defaults.set("unknown", forKey: "menuBarDisplay")
        defaults.set("unknown", forKey: "menuBarDateFormat")
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard button.image != nil, button.title == "  " + MenuBarDateFormat.monthDayWeekday.title(for: model.engine.info(for: model.today)) else {
            throw CocoaError(.coderInvalidValue)
        }
        defaults.set(MenuBarDisplay.iconAndDate.rawValue, forKey: "menuBarDisplay")
        defaults.set(MenuBarDateFormat.numericDate.rawValue, forKey: "menuBarDateFormat")
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        try saveViewSnapshot(button, name: "menubar-icon-and-date", to: directory)
        button.appearance = nil
    }

    private func calendarTimelineTable() throws -> NSTableView {
        func find(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.identifier?.rawValue == "calendarTimeline" { return table }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        guard let root = hostingController?.view, let table = find(in: root) else {
            throw CocoaError(.coderInvalidValue)
        }
        return table
    }

    private func assertCalendarAccent(_ button: NSButton, expected: Bool) throws {
        guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        button.cacheDisplay(in: button.bounds, to: bitmap)
        var colored = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if components.max()! - components.min()! > 0.12 { colored = true }
            }
        }
        guard colored == expected else {
            fputs("月份区块配色错误：\(button.title)，预期彩色=\(expected)，实际=\(colored)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func verifyCalendarTimeline(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        defaults.set(1, forKey: "firstWeekday")
        model.select(model.engine.date(2026, 10, 23))
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        let table = try calendarTimelineTable()
        guard let scroll = table.enclosingScrollView else { throw CocoaError(.coderInvalidValue) }
        // 以下直接移动视口验证自由浏览，先执行与滚轮开始相同的释放动作。
        (scroll as? CalendarTimelineScrollView)?.onActivity?()
        let timeline = CalendarTimeline(engine: model.engine, firstWeekday: 1)
        let firstRow = timeline.weekRow(containing: model.engine.date(2026, 10, 1))
        guard let firstWeek = table.view(atColumn: 0, row: firstRow, makeIfNecessary: false),
              let paddingDay = firstWeek.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "2026年9月27日" }),
              let nationalDay = firstWeek.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "2026年10月1日" }) else {
            throw CocoaError(.coderInvalidValue)
        }
        try assertCalendarAccent(paddingDay, expected: false)
        try assertCalendarAccent(nationalDay, expected: true)
        let selected = model.selection
        let before = scroll.contentView.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: before + 17))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(200))
        guard abs(scroll.contentView.bounds.minY - before - 17) < 1, model.selection == selected else {
            fputs("连续日历小幅滚动被吸附或改变选择\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        let octoberRow = timeline.weekRow(containing: model.engine.date(2026, 10, 18))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: octoberRow).minY - 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await saveSnapshot("timeline-october-november", to: directory)
        let position = scroll.contentView.bounds.minY
        let novemberRow = timeline.weekRow(containing: model.engine.date(2026, 11, 5))
        guard let week = table.view(atColumn: 0, row: novemberRow, makeIfNecessary: false),
              let button = week.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "2026年11月5日" }),
              let window = button.window else { throw CocoaError(.coderInvalidValue) }
        guard model.month == model.engine.date(2026, 10, 1),
              let solarTerm = week.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "2026年11月7日" }) else {
            throw CocoaError(.coderInvalidValue)
        }
        try assertCalendarAccent(solarTerm, expected: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw CocoaError(.coderInvalidValue) }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(300))
        try await waitForCalendarTransition()
        guard model.selection == model.engine.date(2026, 11, 5),
              abs(scroll.contentView.bounds.minY - position) < 1 else {
            fputs("连续日历点击日期失败或导致位置跳动：selection=\(model.selection)，期望偏移=\(position)，实际=\(scroll.contentView.bounds.minY)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("timeline-selected", to: directory)
        guard let friday = week.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "2026年11月6日" }),
              friday.accessibilityRole() == .button, friday.accessibilityPerformPress() else {
            throw CocoaError(.coderInvalidValue)
        }
        try await Task.sleep(for: .milliseconds(150))
        guard model.selection == model.engine.date(2026, 11, 6),
              abs(scroll.contentView.bounds.minY - position) < 1 else { throw CocoaError(.coderInvalidValue) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: novemberRow).minY + 11))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(200))
        guard model.month == model.engine.date(2026, 11, 1) else {
            fputs("连续日历滚动后标题月份未更新\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("timeline-november-active", to: directory)
        defaults.set("dark", forKey: "appearance")
        try await saveSnapshot("timeline-november-active-dark", to: directory)
        defaults.set("light", forKey: "appearance")
        let benchmarkOrigin = scroll.contentView.bounds.minY
        let benchmarkSelection = model.selection
        var samples: [Double] = []
        for index in 0..<120 {
            let step = index < 60 ? index + 1 : 119 - index
            let start = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: NSPoint(x: 0, y: benchmarkOrigin + CGFloat(step) * 24))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            table.window?.displayIfNeeded()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }
        guard model.selection == benchmarkSelection else { throw CocoaError(.coderInvalidValue) }
        let sorted = samples.sorted()
        let benchmark: [String: Any] = [
            "measurement": "主线程滚动、布局与同步绘制耗时，不等于屏幕帧率",
            "steps": samples.count, "stepPoints": 24,
            "medianMS": sorted[sorted.count / 2], "p95MS": sorted[Int(Double(sorted.count) * 0.95)],
            "maxMS": sorted.last!, "samplesMS": samples
        ]
        try JSONSerialization.data(withJSONObject: benchmark, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("timeline-scroll-benchmark.json"))
        let restoredOffset = table.visibleRect.minY - table.rect(ofRow: novemberRow).minY
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(150))
        model.showingSettings = false
        try await Task.sleep(for: .milliseconds(300))
        try await waitForCalendarTransition()
        let restored = try calendarTimelineTable()
        // 长列表重建后绝对行坐标可能重新估算，用户可见的周与周内偏移必须保持一致。
        let actualOffset = restored.visibleRect.minY - restored.rect(ofRow: novemberRow).minY
        guard abs(actualOffset - restoredOffset) < 1 else {
            fputs("连续日历退出设置后未恢复周内位置：期望 \(restoredOffset)，实际 \(actualOffset)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        model.moveMonth(1)
        try await Task.sleep(for: .milliseconds(200))
        guard model.selection == model.engine.date(2026, 12, 6) else { throw CocoaError(.coderInvalidValue) }
        defaults.set("dark", forKey: "appearance")
        model.select(model.engine.date(2026, 12, 31))
        try await saveSnapshot("timeline-cross-year-dark", to: directory)
        model.select(model.engine.date(1901, 1, 1))
        try await saveSnapshot("timeline-lower-bound", to: directory)
        model.selectVisibleDay(model.engine.date(1900, 12, 31))
        guard model.selection == model.engine.date(1901, 1, 1) else { throw CocoaError(.coderInvalidValue) }
        model.select(model.engine.date(2100, 12, 31))
        try await saveSnapshot("timeline-upper-bound", to: directory)
        model.selectVisibleDay(model.engine.date(2101, 1, 1))
        guard model.selection == model.engine.date(2100, 12, 31) else { throw CocoaError(.coderInvalidValue) }
        defaults.set(2, forKey: "firstWeekday")
        defaults.set("light", forKey: "appearance")
        model.select(model.engine.date(2026, 11, 1))
        try await saveSnapshot("timeline-november-padding-monday", to: directory)
        model.goToToday()
        try await saveSnapshot("timeline-today-monday", to: directory)
        guard model.selection == model.today, model.month == model.engine.monthStart(model.today) else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func verifyMonthSnapping(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        defaults.set(1, forKey: "firstWeekday")
        model.select(model.engine.date(2026, 10, 24))
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        let table = try calendarTimelineTable()
        guard let scroll = table.enclosingScrollView as? CalendarTimelineScrollView else { throw CocoaError(.coderInvalidValue) }
        let timeline = CalendarTimeline(engine: model.engine, firstWeekday: 1)
        let selection = model.selection
        func wheel(_ delta: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0,
                   in target: CalendarTimelineScrollView? = nil) throws {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: delta, wheel2: 0, wheel3: 0) else { throw CocoaError(.coderInvalidValue) }
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            guard let event = NSEvent(cgEvent: cg) else { throw CocoaError(.coderInvalidValue) }
            (target ?? scroll).scrollWheel(with: event)
        }
        func position(_ date: Date, offset: CGFloat) {
            let row = timeline.weekRow(containing: date)
            let point = table.convert(NSPoint(x: 0, y: table.rect(ofRow: row).minY + offset), to: scroll.contentView)
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func assertFullMonth(_ date: Date, weekdays: Int = 1, in target: NSTableView? = nil) throws {
            let table = target ?? table
            let layout = CalendarTimeline(engine: model.engine, firstWeekday: weekdays)
            let month = model.engine.monthStart(date)
            let last = model.engine.addingDays(-1, to: model.engine.addingMonths(1, to: month))
            let firstRow = layout.weekRow(containing: month)
            let lastRow = layout.weekRow(containing: last)
            let top = table.rect(ofRow: firstRow).minY
            let bottom = table.rect(ofRow: lastRow).maxY
            guard model.calendarSnappedMonth == month, model.month == month,
                  table.rect(ofRow: firstRow - 1).maxY <= table.visibleRect.minY + 1,
                  abs(table.visibleRect.minY - top) < 1,
                  abs(table.visibleRect.maxY - bottom) < 1 else {
                fputs("整月吸附布局不完整：\(month)，visible=\(table.visibleRect)，rows=\(top)...\(bottom)，state=\(String(describing: model.calendarSnappedMonth))\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        func verifySnapRange(_ date: Date, weekdays: Int, in table: NSTableView) async throws {
            guard let scroll = table.enclosingScrollView as? CalendarTimelineScrollView else {
                throw CocoaError(.coderInvalidValue)
            }
            let layout = CalendarTimeline(engine: model.engine, firstWeekday: weekdays)
            let first = layout.weekRow(containing: date)
            let firstRect = table.rect(ofRow: first)
            let secondRect = table.rect(ofRow: first + 1)
            let thirdRect = table.rect(ofRow: first + 2)
            let offsets: [(String, CGFloat, Bool)] = [
                ("月初前范围外", -45, false), ("月初前边界", -44, true),
                ("月份标题", -15, true), ("第一行中部", firstRect.height / 2, true),
                ("第二行起点", secondRect.minY - firstRect.minY, true),
                ("第二行中部", secondRect.midY - firstRect.minY, true),
                ("第二行末尾", thirdRect.minY - firstRect.minY - 0.5, true),
                ("第三行起点", thirdRect.minY - firstRect.minY, false),
                ("第三行中部", thirdRect.midY - firstRect.minY, false)
            ]
            let selected = model.selection
            for (name, offset, shouldSnap) in offsets {
                try wheel(phase: 1, in: scroll)
                let point = table.convert(NSPoint(x: 0, y: table.rect(ofRow: first).minY + offset), to: scroll.contentView)
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
                try wheel(phase: 4, in: scroll)
                try await Task.sleep(for: .milliseconds(550))
                let actual = table.visibleRect.minY - table.rect(ofRow: first).minY
                guard model.selection == selected,
                      shouldSnap ? model.calendarSnappedMonth == date && abs(actual) < 1
                          : model.calendarSnappedMonth == nil && abs(actual - offset) < 0.1 else {
                    fputs("前两行吸附范围错误：\(date)，星期起始=\(weekdays)，\(name)，偏移=\(offset) → \(actual)，应吸附=\(shouldSnap)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                if shouldSnap { try assertFullMonth(date, weekdays: weekdays, in: table) }
            }
        }
        for (year, month) in [(2026, 2), (2026, 12), (2026, 8), (2027, 1)] {
            try await verifySnapRange(model.engine.date(year, month, 1), weekdays: 1, in: table)
        }
        var motionReports: [[String: Any]] = []
        // 观察整个过渡，防止最终位置正确却在首帧改变行高、隐藏标题或重建周视图。
        for (month, weekCount, offset) in [(2, 4, -22.0), (9, 5, 20.0), (8, 6, -22.0)] {
            let date = model.engine.date(2026, month, 1)
            try wheel(phase: 1)
            position(date, offset: offset)
            try await Task.sleep(for: .milliseconds(100))
            let first = timeline.weekRow(containing: date)
            let rows = Array((first - 1)..<(first + weekCount))
            let heights = rows.map { table.rect(ofRow: $0).height }
            let weekView = table.view(atColumn: 0, row: first, makeIfNecessary: false)
            let startOffset = table.visibleRect.minY - table.rect(ofRow: first).minY
            var previousOffset = startOffset
            var samples: [[String: Double]] = []
            let started = ProcessInfo.processInfo.systemUptime
            try wheel(phase: 4)
            while ProcessInfo.processInfo.systemUptime - started < 0.65 {
                try await Task.sleep(for: .milliseconds(8))
                for (row, height) in zip(rows, heights) {
                    guard abs(table.rect(ofRow: row).height - height) < 0.01,
                          !table.hiddenRowIndexes.contains(row) else {
                        fputs("吸附过渡改变了行高或隐藏行：\(month)月，第\(row - first)行\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                }
                guard table.view(atColumn: 0, row: first, makeIfNecessary: false) === weekView else {
                    fputs("吸附过渡重建了可见周视图\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                let current = table.visibleRect.minY - table.rect(ofRow: first).minY
                guard abs(current) <= abs(previousOffset) + 0.6,
                      current * startOffset >= -0.6 else {
                    fputs("吸附过渡反向跳动或越过目标：\(previousOffset) → \(current)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                samples.append(["elapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                                "offset": current])
                previousOffset = current
            }
            try assertFullMonth(date)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                guard samples.filter({ abs($0["offset"]!) > 1 && abs($0["offset"]!) < Double(abs(startOffset)) - 1 }).count >= 3 else {
                    fputs("吸附缺少连续的中间位置\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
            }
            motionReports.append(["month": month, "weeks": weekCount, "rowHeights": heights, "samples": samples])
            let beforeRelease = table.visibleRect.minY
            try wheel(phase: 1)
            guard abs(table.visibleRect.minY - beforeRelease) < 0.01,
                  rows.map({ table.rect(ofRow: $0).height }) == heights else {
                fputs("解除吸附改变了布局或滚动位置\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            try wheel(phase: 4)
        }
        try JSONSerialization.data(withJSONObject: motionReports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("snap-motion.json"))
        model.select(selection)
        try await Task.sleep(for: .milliseconds(300))
        try await waitForCalendarTransition()
        try assertFullMonth(model.month)
        try wheel(-3, phase: 1)
        position(model.engine.date(2026, 9, 1), offset: -22)
        try await Task.sleep(for: .milliseconds(450))
        try await waitForCalendarTransition()
        guard scroll.gestureActive, model.calendarSnappedMonth == nil else { throw CocoaError(.coderInvalidValue) }
        try wheel(phase: 4)
        try wheel(-1, momentum: 1)
        try await Task.sleep(for: .milliseconds(450))
        try await waitForCalendarTransition()
        guard scroll.gestureActive, model.calendarSnappedMonth == nil else { throw CocoaError(.coderInvalidValue) }
        try wheel(momentum: 3)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForCalendarTransition()
        try assertFullMonth(model.engine.date(2026, 9, 1))
        guard model.selection == selection else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("snap-september-five-weeks", to: directory)

        // 再次滚动立即释放整月布局；停在月中不应被拉回月初。
        try wheel(-4)
        // AppKit 会在后续运行循环应用滚轮位移，待其落定后设置测试锚点。
        try await Task.sleep(for: .milliseconds(100))
        position(model.engine.date(2026, 9, 13), offset: 17)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForCalendarTransition()
        guard model.calendarSnappedMonth == nil else { fputs("月中触发了吸附\n", stderr); throw CocoaError(.coderInvalidValue) }
        let midOffset = table.visibleRect.minY - table.rect(ofRow: timeline.weekRow(containing: model.engine.date(2026, 9, 13))).minY
        guard abs(midOffset - 17) < 1 else { fputs("月中偏移错误：\(midOffset)\n", stderr); throw CocoaError(.coderInvalidValue) }

        // 动画开始后重新触摸，旧任务不得继续写滚动位置。
        try wheel()
        position(model.engine.date(2026, 8, 1), offset: 20)
        // 原生滚轮的 live-scroll 结束通知可能晚于事件返回，按实际动画状态等待。
        for _ in 0..<100 {
            if model.calendarSnappedMonth != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard model.calendarSnappedMonth == model.engine.date(2026, 8, 1) else {
            fputs("中断验证前尚未进入八月吸附动画\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try wheel(phase: 1)
        position(model.engine.date(2026, 8, 16), offset: 13)
        try await Task.sleep(for: .milliseconds(350))
        guard model.calendarSnappedMonth == nil else { throw CocoaError(.coderInvalidValue) }
        try wheel(phase: 4)
        try await Task.sleep(for: .milliseconds(450))
        try await waitForCalendarTransition()
        guard model.calendarSnappedMonth == nil else { throw CocoaError(.coderInvalidValue) }
        let interruptedOffset = table.visibleRect.minY - table.rect(ofRow: timeline.weekRow(containing: model.engine.date(2026, 8, 16))).minY
        guard abs(interruptedOffset - 13) < 1 else {
            fputs("中断后周内偏移错误：\(interruptedOffset)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }

        // 旧停止任务不能覆盖明确导航到的新月份。
        try wheel()
        position(model.engine.date(2026, 9, 1), offset: -20)
        model.select(model.engine.date(2026, 12, 15))
        try await Task.sleep(for: .milliseconds(500))
        try await waitForCalendarTransition()
        try assertFullMonth(model.engine.date(2026, 12, 1))

        // 切换设置拆除列表后，待执行任务不应留下吸附状态。
        try wheel()
        position(model.engine.date(2026, 11, 1), offset: -20)
        try await Task.sleep(for: .milliseconds(50))
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard model.calendarSnappedMonth == nil else {
            fputs("设置打开后仍有吸附状态\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        model.showingSettings = false
        try await Task.sleep(for: .milliseconds(300))
        try await waitForCalendarTransition()

        for (year, month, name) in [(2026, 8, "six-weeks"), (2026, 2, "four-weeks"),
                                    (1901, 1, "lower-bound"), (2100, 12, "upper-bound")] {
            model.select(model.engine.date(year, month, 1))
            try await Task.sleep(for: .milliseconds(300))
            try await waitForCalendarTransition()
            try assertFullMonth(model.month, in: try calendarTimelineTable())
            try await saveSnapshot("snap-" + name, to: directory)
        }
        defaults.set("dark", forKey: "appearance")
        defaults.set(2, forKey: "firstWeekday")
        model.select(model.engine.date(2026, 3, 1))
        try await Task.sleep(for: .milliseconds(300))
        try await waitForCalendarTransition()
        for (year, month) in [(2021, 2), (2026, 12), (2026, 3)] {
            try await verifySnapRange(model.engine.date(year, month, 1), weekdays: 2, in: try calendarTimelineTable())
        }
        model.select(model.engine.date(2026, 3, 1))
        try await Task.sleep(for: .milliseconds(300))
        try assertFullMonth(model.month, weekdays: 2, in: try calendarTimelineTable())
        try await saveSnapshot("snap-six-weeks-monday-dark", to: directory)
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(150))
        model.showingSettings = false
        try await Task.sleep(for: .milliseconds(300))
        try await waitForCalendarTransition()
        try assertFullMonth(model.month, weekdays: 2, in: try calendarTimelineTable())
        defaults.set("light", forKey: "appearance")
        model.goToToday()
    }

    private func verifyOverviewHover(directory: URL) async throws {
        let table = try overviewTable()
        guard let scroll = table.enclosingScrollView, let window = table.window else {
            throw CocoaError(.coderInvalidValue)
        }
        let origin = scroll.contentView.bounds.origin
        defer {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for offset in [0, 136, 272, 136, 0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: origin.y + CGFloat(offset)))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            let rows = table.rows(in: table.visibleRect)
            let buttons = (rows.location..<NSMaxRange(rows)).flatMap { row -> [NSButton] in
                guard let pair = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MonthPairView else { return [] }
                return pair.subviews.compactMap { $0 as? NSButton }
            }
            // 模拟滚动期间迟到的进入通知；实际鼠标位置仍只能命中一个月份。
            guard let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else {
                throw CocoaError(.coderInvalidValue)
            }
            buttons.forEach { $0.mouseEntered(with: entered) }
            var shaded = 0
            for button in buttons where button.visibleRect.height > 60 {
                guard let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
                    throw CocoaError(.coderInvalidValue)
                }
                button.cacheDisplay(in: button.bounds, to: bitmap)
                guard let edge = bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)?.usingColorSpace(.deviceRGB),
                      let inside = bitmap.colorAt(x: bitmap.pixelsWide - 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
                    throw CocoaError(.coderInvalidValue)
                }
                let edgeBrightness = edge.redComponent * edge.alphaComponent + 1 - edge.alphaComponent
                let insideBrightness = inside.redComponent * inside.alphaComponent + 1 - inside.alphaComponent
                if edgeBrightness - insideBrightness > 0.015 { shaded += 1 }
            }
            guard shaded <= 1 else {
                fputs("年概览滚动残留多个月份悬停灰底：\(shaded)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        try await saveSnapshot("year-overview-hover-scrolled", to: directory)
    }

    private func benchmarkOverviewScroll(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        model.openYearOverview()
        try await Task.sleep(for: .milliseconds(500))
        try await waitForCalendarTransition()
        let table = try overviewTable()
        guard let scroll = table.enclosingScrollView, let window = table.window else {
            throw CocoaError(.coderInvalidValue)
        }
        let origin = scroll.contentView.bounds.origin.y
        let selected = model.selection
        var samples: [Double] = []
        for index in 0..<240 {
            let step = index < 120 ? index + 1 : 239 - index
            let start = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to: NSPoint(x: 0, y: origin + CGFloat(step) * 40))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            guard abs(scroll.contentView.bounds.origin.y - (origin + CGFloat(step) * 40)) < 1,
                  model.selection == selected else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(8))
        }
        let sorted = samples.sorted()
        let result: [String: Any] = [
            "measurement": "主线程滚动、布局与同步绘制耗时；不等于屏幕呈现帧率",
            "steps": samples.count, "stepPoints": 40,
            "medianMS": sorted[sorted.count / 2], "p95MS": sorted[Int(Double(sorted.count) * 0.95)],
            "maxMS": sorted.last!, "over16_7MS": samples.filter { $0 > 16.7 }.count,
            "samplesMS": samples
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("scroll-benchmark.json"))
        try await saveSnapshot("scroll-benchmark", to: directory)
    }

    private func overviewTable() throws -> NSTableView {
        func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable(in: $0) }.first
        }
        guard let view = hostingController?.view, let table = findTable(in: view) else {
            throw CocoaError(.coderInvalidValue)
        }
        return table
    }

    private func assertOverviewVisible(year: Int, month: Int) throws {
        let table = try overviewTable()
        let row = (year - CalendarEngine.years.lowerBound) * 7 + 1 + (month - 1) / 2
        guard NSLocationInRange(row, table.rows(in: table.visibleRect)),
              table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil else {
            fputs("年概览定位失败：\(year)年\(month)月，概览状态=\(model?.showingYearOverview ?? false)，目标=\(model?.overviewTarget ?? 0)，表格=\(table.identifier?.rawValue ?? "nil")，过渡=\(presentationController?.isTransitioning ?? false)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func clickOverviewMonth(year: Int, month: Int) async throws {
        let table = try overviewTable()
        let row = (year - CalendarEngine.years.lowerBound) * 7 + 1 + (month - 1) / 2
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false),
              let window = cell.window else { throw CocoaError(.coderInvalidValue) }
        let point = cell.convert(NSPoint(x: cell.bounds.width * (month % 2 == 1 ? 0.25 : 0.75),
                                        y: cell.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw CocoaError(.coderInvalidValue)
            }
            NSApp.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
    }

    private func scrollOverview(by amount: CGFloat) throws {
        func findScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll(in: $0) }.first
        }
        guard let view = hostingController?.view, let scroll = findScroll(in: view),
              let document = scroll.documentView else { throw CocoaError(.coderInvalidValue) }
        let before = scroll.contentView.bounds.origin.y
        let limit = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let after = min(max(0, before + (document.isFlipped ? amount : -amount)), limit)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: after))
        scroll.reflectScrolledClipView(scroll.contentView)
        guard abs(scroll.contentView.bounds.origin.y - before) > 100 else {
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func verifySettingsTransition(directory: URL) async throws {
        guard let model, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        let wasSettings = model.showingSettings
        let wasYearOverview = model.showingYearOverview
        let selection = model.selection
        let preferences = ["appearance", "blurEnabled"].map { ($0, defaults.object(forKey: $0)) }
        panel.behavior = .applicationDefined
        presentation.reduceMotionOverride = false
        defer {
            panel.behavior = behavior
            presentation.reduceMotionOverride = nil
            for (key, value) in preferences {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        // 上一个检查在 defer 中恢复偏好；先完成外观与控件更新，再捕获离开页面的快照。
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        model.showingSettings = false
        model.showingYearOverview = false
        model.select(model.engine.date(2026, 10, 24))
        try await Task.sleep(for: .milliseconds(450))
        try await waitForCalendarTransition()
        var report: [[String: Any]] = []
        func pressEscape() throws {
            guard let window = hostingController?.view.window,
                  let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                      isARepeat: false, keyCode: 53) else { throw CocoaError(.coderInvalidValue) }
            NSApp.postEvent(escape, atStart: false)
        }
        func sample(_ name: String, settings: Bool, reduced: Bool = false) async throws {
            guard let shell = presentation.shell else { throw CocoaError(.coderInvalidValue) }
            let size = panel.contentSize
            let material = presentation.material
            let selection = model.selection
            let sourceCard = shell.content.frame
            var frames: [[String: Double]] = []
            model.showingSettings = settings
            let began = ProcessInfo.processInfo.systemUptime
            var savedMiddle = false
            while presentation.isTransitioning, ProcessInfo.processInfo.systemUptime - began < 2 {
                try await Task.sleep(for: .milliseconds(8))
                guard presentation.shell === shell, presentation.material === material,
                      shell.chromeCoverage >= 0.999,
                      !shell.header.isHiddenOrHasHiddenAncestor, !shell.footer.isHiddenOrHasHiddenAncestor,
                      abs(panel.contentSize.height - size.height) < 1 else {
                    fputs("设置过渡重建外壳、隐藏上下栏或改变弹窗高度：\(name)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                if presentation.hasActiveFrameDriver, let card = presentation.movingCardFrame {
                    guard presentation.matchedDayCount == 0, shell.content.alphaValue == 0 else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    let footer = presentation.view.convert(shell.footer.bounds, from: shell.footer)
                    guard abs(footer.minY - card.maxY) < 1 else { throw CocoaError(.coderInvalidValue) }
                    frames.append(["top": card.minY, "bottom": card.maxY, "height": card.height,
                                   "progress": presentation.progress, "time": presentation.elapsedFraction,
                                   "seconds": presentation.motionSeconds, "outgoing": presentation.outgoingOpacity,
                                   "incoming": presentation.incomingOpacity, "chromeCoverage": shell.chromeCoverage])
                    if !savedMiddle, presentation.progress > 0.35 {
                        try saveViewSnapshot(presentation.view, name: name + "-middle", to: directory)
                        savedMiddle = true
                    }
                }
            }
            guard frames.count >= 3, savedMiddle, !presentation.isTransitioning,
                  presentation.transitionView == nil, !presentation.hasActiveFrameDriver,
                  presentation.shell === shell, shell.content.alphaValue == 1,
                  shell.transitionCard == nil, model.showingSettings == settings,
                  model.selection == selection, abs(panel.contentSize.height - size.height) < 1 else {
                fputs("设置过渡缺少中间帧或未恢复真实内容：\(name)，采样=\(frames.count)，进度=\(presentation.progress)，运动时间=\(presentation.motionSeconds)，回调=\(presentation.driverCallbackCount)，驱动=\(presentation.hasActiveFrameDriver)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            let destination = shell.content.frame
            if reduced {
                guard frames.allSatisfy({ abs($0["top"]! - destination.minY) < 1 && abs($0["bottom"]! - destination.maxY) < 1 }) else {
                    throw CocoaError(.coderInvalidValue)
                }
            } else {
                try validatePresentationTiming(frames, name: name)
                let settling = frames.filter { $0["seconds"]! >= 0.22 && $0["seconds"]! <= 0.28 }
                guard !settling.isEmpty, settling.allSatisfy({ $0["progress"]! >= 0.95 }),
                      frames.allSatisfy({ $0["seconds"]! <= 0.45 }) else {
                    fputs("设置过渡未及时接近终点或收尾过长：\(name)，末帧时间=\(frames.last?["seconds"] ?? 0)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                guard Set(frames.map { Int($0["height"]! * 2) }).count >= 3,
                      abs(sourceCard.height - destination.height) > 10 else {
                    fputs("设置白色容器未按弹簧曲线连续形变：\(name)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                for pair in zip(frames, frames.dropFirst()) {
                    for (edge, target) in [("top", destination.minY), ("bottom", destination.maxY)] {
                        guard abs(pair.1[edge]! - target) <= abs(pair.0[edge]! - target) + 0.5 else {
                            throw CocoaError(.coderInvalidValue)
                        }
                    }
                }
            }
            let callbacks = presentation.driverCallbackCount
            try await Task.sleep(for: .milliseconds(40))
            guard presentation.driverCallbackCount == callbacks else { throw CocoaError(.coderInvalidValue) }
            report.append(["name": name, "frames": frames, "windowHeight": size.height,
                           "preparationMS": presentation.preparationMilliseconds,
                           "preparationPhases": presentation.preparationPhases])
            try saveViewSnapshot(presentation.view, name: name + "-end", to: directory)
        }
        for appearance in ["light", "dark"] {
            for blur in [true, false] {
                defaults.set(appearance, forKey: "appearance")
                defaults.set(blur, forKey: "blurEnabled")
                try await Task.sleep(for: .milliseconds(300))
                try await waitForCalendarTransition()
                let name = "settings-transition-\(appearance)-\(blur ? "blur" : "solid")"
                try await sample(name + "-in", settings: true)
                try await sample(name + "-out", settings: false)
            }
        }
        for (name, date) in [("ordinary", model.engine.date(2026, 10, 25)),
                             ("holiday", model.engine.date(2026, 10, 1))] {
            model.select(date)
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
            try await sample("settings-transition-\(name)-in", settings: true)
            try await sample("settings-transition-\(name)-out", settings: false)
        }
        model.openYearOverview()
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        try await sample("settings-transition-year-in", settings: true)
        try await sample("settings-transition-year-out", settings: false)
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(60))
        try pressEscape()
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard !model.showingSettings, model.showingYearOverview, panel.isShown,
              !presentation.isTransitioning, presentation.shell?.content.alphaValue == 1 else {
            throw CocoaError(.coderInvalidValue)
        }
        model.showingYearOverview = false
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        presentation.reduceMotionOverride = true
        try await sample("settings-transition-reduced-in", settings: true, reduced: true)
        try await sample("settings-transition-reduced-out", settings: false, reduced: true)
        presentation.reduceMotionOverride = false
        for interruption in ["preparation", "reverse", "close"] {
            model.showingSettings = true
            if interruption != "preparation" { try await Task.sleep(for: .milliseconds(60)) }
            switch interruption {
            case "close": panel.performClose(nil)
            case "reverse": try pressEscape()
            default: model.showingSettings = false
            }
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
            let callbacks = presentation.driverCallbackCount
            try await Task.sleep(for: .milliseconds(40))
            guard !presentation.isTransitioning, !presentation.hasActiveFrameDriver,
                  presentation.transitionView == nil, presentation.shell?.content.alphaValue == 1,
                  presentation.driverCallbackCount == callbacks,
                  interruption == "close" || (!model.showingSettings && panel.isShown) else {
                throw CocoaError(.coderInvalidValue)
            }
            if interruption == "close" { showPanel() }
            model.showingSettings = false
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
        }
        model.select(selection)
        model.showingYearOverview = wasYearOverview
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        model.showingSettings = wasSettings
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("settings-transition-motion.json"))
    }

    private func verifyAppUpdates(directory: URL) async throws {
        guard let model, let view = hostingController?.view, appUpdater.isAvailable,
              !appUpdater.automaticallyChecks, !appUpdater.automaticallyInstalls else {
            throw CocoaError(.coderInvalidValue)
        }
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(500))
        try await waitForCalendarTransition()
        try scrollSettings(toBottom: true)
        func element(_ label: String) throws -> AnyObject {
            func find(_ node: AnyObject) -> AnyObject? {
                if node.accessibilityLabel?() == label { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let result = find(child as AnyObject) { return result }
                }
                return nil
            }
            guard let result = find(view) else { throw CocoaError(.coderInvalidValue) }
            return result
        }
        func press(_ label: String) async throws {
            guard try element(label).accessibilityPerformPress?() == true else {
                throw CocoaError(.coderInvalidValue)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard try element("自动下载并安装").isAccessibilityEnabled?() == false else {
            throw CocoaError(.coderInvalidValue)
        }
        appUpdater.setAutomaticallyInstalls(true)
        guard !appUpdater.automaticallyInstalls else { throw CocoaError(.coderInvalidValue) }
        try await press("自动检查更新")
        try await press("自动下载并安装")
        guard appUpdater.automaticallyChecks, appUpdater.automaticallyInstalls,
              let path = ProcessInfo.processInfo.environment["DAYORDER_UPDATE_TEST_BUNDLE"],
              let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier,
              let stored = UserDefaults(suiteName: identifier),
              stored.bool(forKey: "SUEnableAutomaticChecks"), stored.bool(forKey: "SUAutomaticallyUpdate") else {
            throw CocoaError(.coderInvalidValue)
        }
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            try await saveSnapshot("settings-updates-\(appearance)", to: directory)
        }
        try await press("自动检查更新")
        guard !appUpdater.automaticallyChecks, !appUpdater.automaticallyInstalls,
              !stored.bool(forKey: "SUEnableAutomaticChecks"), !stored.bool(forKey: "SUAutomaticallyUpdate") else {
            throw CocoaError(.coderInvalidValue)
        }
        appUpdater.checkForUpdateInformation()
        let deadline = Date().addingTimeInterval(20)
        while appUpdater.message == nil || appUpdater.isBusy {
            guard Date() < deadline else { throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let expected = ProcessInfo.processInfo.environment["DAYORDER_UPDATE_TEST_EXPECTED"] ?? "发现新版本"
        guard appUpdater.message?.contains(expected) == true, appUpdater.canCheck else {
            fputs("更新检查结果不符：\(appUpdater.message ?? "nil")\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("settings-updates-result", to: directory)
    }

    private func verifySettingsDesign(directory: URL) async throws {
        guard let model, let view = hostingController?.view, let presentation = presentationController else {
            throw CocoaError(.coderInvalidValue)
        }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        let keys = ["appearance", "blurEnabled", "menuBarDisplay", "menuBarDateFormat", "firstWeekday", "showSolarTerms",
                    CalendarRefreshPolicy.preferenceKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            panel.behavior = behavior
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func element(_ label: String) throws -> AnyObject {
            func find(_ node: AnyObject) -> AnyObject? {
                if node.accessibilityLabel?() == label { return node }
                for child in node.accessibilityChildren?() ?? [] {
                    if let found = find(child as AnyObject) { return found }
                }
                return nil
            }
            guard let result = find(view) else {
                fputs("设置控件不可访问：\(label)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            return result
        }
        func press(_ label: String) async throws {
            guard try element(label).accessibilityPerformPress?() == true else {
                fputs("无法操作设置控件：\(label)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
        }
        let originalSelection = model.selection
        let originalYearOverview = model.showingYearOverview
        model.showingSettings = false
        model.showingYearOverview = false
        for (name, date) in [("ordinary", model.engine.date(2026, 10, 25)),
                             ("solar-term", model.engine.date(2026, 10, 24)),
                             ("holiday", model.engine.date(2026, 10, 1))] {
            model.select(date)
            try await Task.sleep(for: .milliseconds(500))
            try await waitForCalendarTransition()
            let calendarSize = view.bounds.size
            try await press("设置")
            guard view.bounds.size == calendarSize, panel.contentSize == calendarSize else {
                fputs("进入设置改变了弹窗尺寸：\(name)，日历=\(calendarSize)，设置=\(view.bounds.size)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            try await saveSnapshot("settings-height-" + name, to: directory)
            try await press("返回日历")
            guard view.bounds.size == calendarSize, model.selection == date else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        model.openYearOverview()
        try await Task.sleep(for: .milliseconds(500))
        try await waitForCalendarTransition()
        let yearSize = view.bounds.size
        model.showingSettings = true
        try await saveSnapshot("settings-height-year", to: directory)
        guard view.bounds.size == yearSize, panel.contentSize == yearSize else {
            fputs("设置没有沿用年概览的高度。\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await press("返回日历")
        guard view.bounds.size == yearSize else { throw CocoaError(.coderInvalidValue) }
        model.showingYearOverview = originalYearOverview
        model.select(originalSelection)
        try await Task.sleep(for: .milliseconds(500))
        try await waitForCalendarTransition()
        let settingsSize = view.bounds.size
        func validateLayout(_ scroll: NSScrollView) throws {
            guard !scroll.hasVerticalScroller, !scroll.hasHorizontalScroller,
                  abs(scroll.frame.width - 308) < 1, abs(scroll.frame.height - (settingsSize.height - 90)) < 1,
                  view.bounds.size == settingsSize else { throw CocoaError(.coderInvalidValue) }
        }
        model.showingSettings = true
        defaults.set(MenuBarDisplay.iconOnly.rawValue, forKey: "menuBarDisplay")
        defaults.set(1, forKey: "firstWeekday")
        defaults.set(true, forKey: "showSolarTerms")
        for appearance in ["light", "dark"] {
            for blur in [true, false] {
                defaults.set(appearance, forKey: "appearance")
                defaults.set(blur, forKey: "blurEnabled")
                try await saveSnapshot("settings-\(blur ? "blur" : "solid")-\(appearance)", to: directory)
                guard let scroll = descendants(view).compactMap({ $0 as? NSScrollView }).first,
                      let document = scroll.documentView,
                      presentation.material.isHidden == !blur else {
                    fputs("设置面板尺寸、滚动条或材质状态不符合设计。\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                try validateLayout(scroll)
                if appearance == "light", blur {
                    // 真实滚动条违反设计时，布局检查必须拒绝；随后恢复同一视图。
                    scroll.hasVerticalScroller = true
                    var rejected = false
                    do { try validateLayout(scroll) } catch { rejected = true }
                    scroll.hasVerticalScroller = false
                    guard rejected else { throw CocoaError(.coderInvalidValue) }
                }
                let returnFrame = try element("返回日历").accessibilityFrame?()
                let exitFrame = try element("退出日序").accessibilityFrame?()
                let topOrigin = scroll.contentView.bounds.origin
                try scrollSettings(toBottom: true)
                try await saveSnapshot("settings-bottom-\(blur ? "blur" : "solid")-\(appearance)", to: directory)
                let returnedFrame = try element("返回日历").accessibilityFrame?()
                let exitedFrame = try element("退出日序").accessibilityFrame?()
                guard returnedFrame == returnFrame,
                      exitedFrame == exitFrame,
                      scroll.contentView.bounds.origin != topOrigin,
                      !scroll.documentVisibleRect.contains(document.bounds) else {
                    fputs("设置滚动改变固定入口或未滚动：\(appearance)/\(blur)，返回=\(String(describing: returnFrame))→\(String(describing: returnedFrame))，退出=\(String(describing: exitFrame))→\(String(describing: exitedFrame))，滚动=\(topOrigin)→\(scroll.contentView.bounds.origin)，文档=\(document.bounds)，可见=\(scroll.documentVisibleRect)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                _ = try element("退出日序")
                try scrollSettings(toBottom: false)
                // 等待原生滚动触发的 SwiftUI 布局完成，再切换下一组外观。
                try await Task.sleep(for: .milliseconds(400))
                try await waitForCalendarTransition()
            }
        }
        defaults.set("light", forKey: "appearance")
        defaults.set(true, forKey: "blurEnabled")
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        try await press("毛玻璃效果")
        guard !defaults.bool(forKey: "blurEnabled"), presentation.material.isHidden else {
            throw CocoaError(.coderInvalidValue)
        }
        try await press("毛玻璃效果")
        guard defaults.bool(forKey: "blurEnabled"), !presentation.material.isHidden else {
            throw CocoaError(.coderInvalidValue)
        }
        try await press("二十四节气")
        guard !defaults.bool(forKey: "showSolarTerms") else { throw CocoaError(.coderInvalidValue) }
        try await press("二十四节气")
        guard defaults.bool(forKey: "showSolarTerms") else { throw CocoaError(.coderInvalidValue) }
        defaults.set(false, forKey: CalendarRefreshPolicy.preferenceKey)
        try await Task.sleep(for: .milliseconds(100))
        try await press("优先高刷新率")
        guard defaults.bool(forKey: CalendarRefreshPolicy.preferenceKey) else { throw CocoaError(.coderInvalidValue) }
        try await press("优先高刷新率")
        guard !defaults.bool(forKey: CalendarRefreshPolicy.preferenceKey) else { throw CocoaError(.coderInvalidValue) }
        defaults.set(MenuBarDisplay.iconAndDate.rawValue, forKey: "menuBarDisplay")
        defaults.set(MenuBarDateFormat.yearMonthDayWeekday.rawValue, forKey: "menuBarDateFormat")
        try await saveSnapshot("settings-long-date-format", to: directory)
        _ = try element("日期格式")
        try scrollSettings(toBottom: true)
        try await press("关于日序")
        try scrollSettings(toBottom: true)
        try await saveSnapshot("settings-about-expanded", to: directory)
        try await press("关于日序")
        let savedMessage = model.holidayUpdateMessages[model.displayedYear]
        model.holidayUpdateMessages[model.displayedYear] = "更新失败：暂时无法连接数据源，继续使用已收录的放假与调休安排。请检查网络连接后重试。"
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        try scrollSettings(toBottom: true)
        try await saveSnapshot("settings-update-message", to: directory)
        model.holidayUpdateMessages[model.displayedYear] = savedMessage
        let selection = model.selection
        try await press("返回日历")
        guard !model.showingSettings, model.selection == selection else { throw CocoaError(.coderInvalidValue) }
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        try scrollSettings(toBottom: false)
        guard let service = smokeLoginService else { throw CocoaError(.coderInvalidValue) }
        func verifyLoginSwitch(_ expected: Bool) throws {
            let control = try element("开机自启") as? NSObject
            let rawValue = control?.perform(NSSelectorFromString("accessibilityValue"))?.takeUnretainedValue()
            let value = rawValue as? NSNumber
            guard value?.boolValue == expected, launchAtLogin.isOn == expected else {
                fputs("开机自启开关未反映系统登记状态：期望=\(expected)，控件=\(String(describing: rawValue))，登记=\(launchAtLogin.isOn)。\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        try verifyLoginSwitch(false)
        try await press("开机自启")
        try verifyLoginSwitch(true)
        guard service.status == .enabled else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("settings-login-enabled", to: directory)
        try await press("开机自启")
        try verifyLoginSwitch(false)
        guard service.status == .notRegistered else { throw CocoaError(.coderInvalidValue) }

        service.registrationStatus = .requiresApproval
        try await press("开机自启")
        try verifyLoginSwitch(true)
        guard launchAtLogin.status == .requiresApproval else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("settings-login-approval", to: directory)
        try await press("打开系统登录项设置")
        guard service.settingsOpenCount == 1 else { throw CocoaError(.coderInvalidValue) }
        // 从系统设置返回时重新读取状态；也覆盖待批准登记的撤销。
        service.status = .enabled
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(400))
        guard launchAtLogin.status == .enabled else { throw CocoaError(.coderInvalidValue) }
        service.status = .requiresApproval
        launchAtLogin.refresh()
        try await Task.sleep(for: .milliseconds(400))
        try await press("开机自启")
        try verifyLoginSwitch(false)

        service.operationError = NSError(domain: "DayOrderSmoke", code: 1,
                                         userInfo: [NSLocalizedDescriptionKey: "系统拒绝了操作，请检查登录项权限。"])
        try await press("开机自启")
        try verifyLoginSwitch(false)
        guard launchAtLogin.errorMessage != nil else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("settings-login-error", to: directory)
        service.operationError = nil
        service.registrationStatus = .enabled
        try await press("开机自启")
        try verifyLoginSwitch(true)
        guard launchAtLogin.errorMessage == nil else { throw CocoaError(.coderInvalidValue) }
        service.operationError = CocoaError(.fileWriteNoPermission)
        try await press("开机自启")
        try verifyLoginSwitch(true)
        guard launchAtLogin.errorMessage != nil else { throw CocoaError(.coderInvalidValue) }
        service.operationError = nil
        service.status = .notRegistered
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(400))
        try verifyLoginSwitch(false)
        guard launchAtLogin.errorMessage == nil else { throw CocoaError(.coderInvalidValue) }

        // 设置关闭期间发生的系统修改，应在下一次进入时反映到开关。
        try await press("返回日历")
        service.status = .enabled
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        try verifyLoginSwitch(true)
        try await press("开机自启")

        let mutations = service.mutationCount
        let unpackaged = service.makeController(isAppBundle: false)
        unpackaged.setEnabled(true)
        guard !unpackaged.canChange, service.mutationCount == mutations else {
            fputs("非应用包入口不应写入系统登录项。\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        service.status = .notFound
        launchAtLogin.refresh()
        try await Task.sleep(for: .milliseconds(400))
        guard launchAtLogin.canChange, service.mutationCount == mutations,
              try element("开机自启").isAccessibilityEnabled?() == true else {
            fputs("未找到登录项记录时，应允许用户主动尝试登记。\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try verifyLoginSwitch(false)
        try await saveSnapshot("settings-login-not-found", to: directory)
        try await press("开机自启")
        try verifyLoginSwitch(true)
        guard service.mutationCount == mutations + 1, launchAtLogin.status == .enabled else {
            throw CocoaError(.coderInvalidValue)
        }
        try await press("开机自启")
        try verifyLoginSwitch(false)

        // 登记失败也可能改变系统状态；刷新不能丢掉本次操作的错误。
        service.registrationFailureStatus = .notFound
        service.operationError = NSError(domain: "DayOrderSmoke", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: "无法登记登录项，请检查应用签名。"])
        let beforeFailure = service.mutationCount
        for attempt in 1...2 {
            try await press("开机自启")
            try verifyLoginSwitch(false)
            guard service.mutationCount == beforeFailure + attempt, launchAtLogin.status == .notFound,
                  launchAtLogin.errorMessage?.contains("无法登记登录项，请检查应用签名。") == true else {
                fputs("登记失败后应保留具体错误，并允许从未找到记录状态重试。\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        try await saveSnapshot("settings-login-not-found-error", to: directory)
        try await press("打开系统登录项设置")
        guard service.settingsOpenCount == 2 else { throw CocoaError(.coderInvalidValue) }
        service.operationError = nil
        service.registrationFailureStatus = nil
        service.registrationStatus = .requiresApproval
        try await press("开机自启")
        try verifyLoginSwitch(true)
        guard launchAtLogin.status == .requiresApproval, launchAtLogin.errorMessage == nil,
              service.mutationCount == beforeFailure + 3 else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("settings-login-not-found-retry", to: directory)
        try await press("开机自启")
        try verifyLoginSwitch(false)
        service.registrationStatus = .enabled
        launchAtLogin.refresh()
    }

    private func scrollSettings(toBottom: Bool) throws {
        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
        }
        guard let view = hostingController?.view, let scroll = findScrollView(in: view),
              let document = scroll.documentView else { throw CocoaError(.coderInvalidValue) }
        let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: toBottom == document.isFlipped ? end : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func verifyTodayScroll(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        defaults.set(1, forKey: "firstWeekday")
        func pressToday() throws {
            func find(in element: AnyObject) -> AnyObject? {
                if element.accessibilityRole?() == .button, element.accessibilityLabel?() == "今天" { return element }
                for child in element.accessibilityChildren?() ?? [] {
                    if let found = find(in: child as AnyObject) { return found }
                }
                return nil
            }
            guard let view = hostingController?.view, let button = find(in: view),
                  button.accessibilityPerformPress?() == true else {
                fputs("无法触发真实今天按钮\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        var reports: [[String: Any]] = []
        for (year, month) in [(2026, 9), (2026, 11), (1901, 1), (2100, 12), (2026, 10)] {
            model.select(model.engine.date(year, month, 24))
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
            let table = try calendarTimelineTable()
            if year == 2026, month == 10, let scroll = table.enclosingScrollView as? CalendarTimelineScrollView {
                scroll.onActivity?()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + 93))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            let timeline = CalendarTimeline(engine: model.engine, firstWeekday: 1)
            let targetRow = timeline.weekRow(containing: model.engine.monthStart(model.today))
            let target = table.rect(ofRow: targetRow).minY
            let start = table.visibleRect.minY
            let startOffset = start - target
            var previousOffset = startOffset
            var samples: [Double] = []
            let expectedDuration = min(0.70, 0.45 + abs(startOffset) / 6000)
            var hasFastStart = false
            var arrivalElapsed: Double?
            let began = ProcessInfo.processInfo.systemUptime
            try pressToday()
            while ProcessInfo.processInfo.systemUptime - began < 1.0 {
                try await Task.sleep(for: .milliseconds(8))
                if arrivalElapsed == nil, model.selection == model.today {
                    arrivalElapsed = ProcessInfo.processInfo.systemUptime - began
                }
                let y = table.visibleRect.minY
                // 原生列表实现远处行时会修正累计坐标，比较相对目标周行的距离。
                let offset = y - table.rect(ofRow: targetRow).minY
                guard abs(offset) <= abs(previousOffset) + 0.6,
                      offset * startOffset >= -0.6 else {
                    fputs("返回今天的滚动反向或越过终点：来源=\(year)-\(month)，初始=\(startOffset)，前次=\(previousOffset)，当前=\(offset)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                if abs(offset) > 1, abs(offset - startOffset) > 1 {
                    guard model.selection != model.today else {
                        fputs("返回今天尚未到达就更新了选择和详情：来源=\(year)-\(month)，位置=\(y)，初始目标=\(target)，当前目标=\(table.rect(ofRow: targetRow).minY)\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                    samples.append(offset)
                    if ProcessInfo.processInfo.systemUptime - began < expectedDuration * 0.6,
                       1 - offset / startOffset > 0.75 {
                        hasFastStart = true
                    }
                }
                previousOffset = offset
            }
            guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || samples.count >= 3 else {
                fputs("返回今天缺少连续中间位置，发生了直接跳转\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || hasFastStart else {
                fputs("返回今天未采用与月份箭头一致的先快后缓减速\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    || (arrivalElapsed.map { $0 >= expectedDuration - 0.04 && $0 < 1.0 } == true) else {
                fputs("返回今天的动画时长未落在预期范围\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            guard abs(table.visibleRect.minY - table.rect(ofRow: targetRow).minY) < 1, model.selection == model.today,
                  model.calendarSnappedMonth == model.engine.monthStart(model.today) else {
                fputs("返回今天未停在完整当月或未选中今天：来源=\(year)-\(month)，位置=\(table.visibleRect.minY)，初始目标=\(target)，当前目标=\(table.rect(ofRow: targetRow).minY)，选择=\(model.selection)，吸附=\(String(describing: model.calendarSnappedMonth))\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            reports.append(["year": year, "month": month, "startOffset": startOffset,
                            "offsets": samples, "hasFastStart": hasFastStart,
                            "arrivalElapsed": arrivalElapsed ?? -1])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("today-scroll-motion.json"))
        let aligned = try calendarTimelineTable().visibleRect.minY
        try pressToday()
        try await Task.sleep(for: .milliseconds(150))
        guard abs(try calendarTimelineTable().visibleRect.minY - aligned) < 0.5 else {
            fputs("今天所在月份已对齐时仍发生移动\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            for interruption in ["wheel-pending", "selection-pending", "wheel", "selection", "navigation", "repeat", "settings", "year", "close"] {
                model.select(model.engine.date(2025, 1, 24))
                try await Task.sleep(for: .milliseconds(300))
                try await waitForCalendarTransition()
                let table = try calendarTimelineTable()
                let originalSelection = model.selection
                try pressToday()
                if !interruption.hasSuffix("-pending") { try await Task.sleep(for: .milliseconds(100)) }
                let position = table.visibleRect.minY
                let viewport = model.calendarViewport
                switch interruption {
                case "wheel", "wheel-pending":
                    guard let scroll = table.enclosingScrollView as? CalendarTimelineScrollView,
                          let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                           wheel1: 0, wheel2: 0, wheel3: 0) else { throw CocoaError(.coderInvalidValue) }
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
                    guard let event = NSEvent(cgEvent: cg) else { throw CocoaError(.coderInvalidValue) }
                    scroll.scrollWheel(with: event)
                case "selection", "selection-pending": model.selectVisibleDay(model.engine.date(2026, 5, 12))
                case "navigation": model.select(model.engine.date(2027, 2, 1))
                case "repeat": try pressToday()
                case "settings": model.showingSettings = true
                case "year": model.openYearOverview()
                default: panel.performClose(nil)
                }
                try await Task.sleep(for: .milliseconds(850))
                if interruption == "repeat" {
                    guard model.selection == model.today else { throw CocoaError(.coderInvalidValue) }
                } else if interruption == "navigation" {
                    guard model.selection == model.engine.date(2027, 2, 1),
                          model.calendarSnappedMonth == model.engine.date(2027, 2, 1) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                } else {
                    let expected = interruption.hasPrefix("selection") ? model.engine.date(2026, 5, 12) : originalSelection
                    guard model.selection == expected else {
                        fputs("取消返回今天后，旧动画覆盖了选择：\(interruption)\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                    if interruption.hasPrefix("wheel") || interruption.hasPrefix("selection") || interruption == "close" {
                        guard abs(table.visibleRect.minY - position) < 1 else {
                            fputs("取消返回今天后仍继续移动：\(interruption)\n", stderr)
                            throw CocoaError(.coderInvalidValue)
                        }
                    }
                }
                if interruption == "settings" || interruption == "year" {
                    model.showingSettings = false
                    model.showingYearOverview = false
                    try await Task.sleep(for: .milliseconds(300))
                    try await waitForCalendarTransition()
                    let restored = try calendarTimelineTable()
                    guard let viewport else { throw CocoaError(.coderInvalidValue) }
                    let layout = CalendarTimeline(engine: model.engine, firstWeekday: 1)
                    let row = layout.weekRow(containing: viewport.date, inMonth: viewport.month)
                    guard abs(restored.visibleRect.minY - restored.rect(ofRow: row).minY - viewport.offset) < 1 else {
                        fputs("中断返回今天后未恢复中途位置：\(interruption)\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                }
                if interruption == "close" {
                    showPanel()
                    model.today = model.engine.date(2026, 10, 23)
                }
            }
        }
        model.goToToday()
        try await saveSnapshot("today-scroll-arrived", to: directory)
    }

    private func verifyMonthNavigationMotion(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        defaults.set(1, forKey: "firstWeekday")
        let timeline = model.calendarTimeline(firstWeekday: 1)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func press(_ label: String) throws {
            func find(_ element: AnyObject) -> AnyObject? {
                if element.accessibilityRole?() == .button, element.accessibilityLabel?() == label { return element }
                for child in element.accessibilityChildren?() ?? [] {
                    if let result = find(child as AnyObject) { return result }
                }
                return nil
            }
            guard let view = hostingController?.view, let button = find(view),
                  button.accessibilityPerformPress?() == true else {
                fputs("无法触发月份导航按钮：\(label)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        func prepare(_ date: Date) async throws {
            model.select(date)
            try await Task.sleep(for: .milliseconds(350))
            try await waitForCalendarTransition()
        }
        func assertArrival(_ date: Date) throws {
            let table = try calendarTimelineTable()
            let month = model.engine.monthStart(date)
            let row = timeline.weekRow(containing: month)
            guard model.selection == date, model.month == month, model.calendarSnappedMonth == month,
                  model.calendarMonthNavigationTarget == nil,
                  abs(table.visibleRect.minY - table.rect(ofRow: row).minY) < 1 else {
                fputs("月份导航未完整对齐目标或未释放请求：\(date)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        var reports: [[String: Any]] = []
        // 包含双向、跨年、短月，以及四、五、六行月份。
        for (source, target, label) in [
            (model.engine.date(2026, 10, 31), model.engine.date(2026, 11, 30), "下个月"),
            (model.engine.date(2026, 3, 31), model.engine.date(2026, 2, 28), "上个月"),
            (model.engine.date(2026, 12, 24), model.engine.date(2027, 1, 24), "下个月"),
            (model.engine.date(2026, 7, 24), model.engine.date(2026, 8, 24), "下个月"),
            (model.engine.date(2015, 3, 24), model.engine.date(2015, 2, 24), "上个月")
        ] {
            try await prepare(source)
            let table = try calendarTimelineTable()
            let row = timeline.weekRow(containing: model.engine.monthStart(target))
            let initial = table.visibleRect.minY - table.rect(ofRow: row).minY
            var previous = initial
            var samples: [[String: Double]] = []
            let began = ProcessInfo.processInfo.systemUptime
            try press(label)
            while ProcessInfo.processInfo.systemUptime - began < 0.65 {
                try await Task.sleep(for: .milliseconds(8))
                let offset = table.visibleRect.minY - table.rect(ofRow: row).minY
                guard abs(offset) <= abs(previous) + 0.6, offset * initial >= -0.6 else {
                    fputs("切月动画反向或越过终点\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                if abs(offset) > 1, abs(offset - initial) > 1 {
                    samples.append(["time": ProcessInfo.processInfo.systemUptime - began,
                                    "progress": 1 - offset / initial])
                }
                previous = offset
            }
            if !reduced {
                guard samples.count >= 3,
                      samples.contains(where: { $0["time"]! < 0.22 && $0["progress"]! > 0.7 }) else {
                    fputs("切月缺少连续位置或先快后缓的非线性减速\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
            }
            try assertArrival(target)
            reports.append(["source": source.description, "target": target.description, "samples": samples])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("month-navigation-motion.json"))
        try await saveSnapshot("month-navigation-arrived", to: directory)

        try await prepare(model.engine.date(2026, 10, 24))
        try press("下个月")
        try press("下个月")
        try await Task.sleep(for: .milliseconds(70))
        try press("下个月")
        try await Task.sleep(for: .milliseconds(550))
        try assertArrival(model.engine.date(2027, 1, 24))
        try press("上个月")
        try await Task.sleep(for: .milliseconds(70))
        let beforeReversal = try calendarTimelineTable().visibleRect.minY
        try press("下个月")
        guard abs(try calendarTimelineTable().visibleRect.minY - beforeReversal) < 1 else {
            fputs("反向切月瞬间跳动\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await Task.sleep(for: .milliseconds(550))
        try assertArrival(model.engine.date(2027, 1, 24))

        if !reduced {
            for interruption in ["wheel-pending", "wheel", "selection-pending", "selection", "settings-pending", "settings", "year-pending", "year", "today"] {
                try await prepare(model.engine.date(2026, 10, 24))
                try press("下个月")
                if !interruption.hasSuffix("-pending") { try await Task.sleep(for: .milliseconds(70)) }
                let table = try calendarTimelineTable()
                let position = table.visibleRect.minY
                switch interruption {
                case "wheel-pending", "wheel":
                    (table.enclosingScrollView as? CalendarTimelineScrollView)?.onActivity?()
                case "selection-pending", "selection": model.selectVisibleDay(model.engine.date(2026, 10, 12))
                case "settings-pending", "settings": model.showingSettings = true
                case "year-pending", "year": model.openYearOverview()
                default: try press("今天")
                }
                try await Task.sleep(for: .milliseconds(interruption == "today" ? 850 : 550))
                if interruption == "today" {
                    try assertArrival(model.today)
                } else {
                    guard model.calendarMonthNavigationTarget == nil else { throw CocoaError(.coderInvalidValue) }
                    if interruption.hasPrefix("selection") {
                        guard model.selection == model.engine.date(2026, 10, 12) else { throw CocoaError(.coderInvalidValue) }
                    }
                    if interruption.hasPrefix("wheel") || interruption.hasPrefix("selection") {
                        guard abs(table.visibleRect.minY - position) < 1 else {
                            fputs("中断切月后旧动画仍移动日期区：\(interruption)\n", stderr)
                            throw CocoaError(.coderInvalidValue)
                        }
                    }
                }
                model.showingSettings = false
                model.showingYearOverview = false
                try await waitForCalendarTransition()
            }
        }
        for (source, target, label) in [
            (model.engine.date(1901, 2, 24), model.engine.date(1901, 1, 24), "上个月"),
            (model.engine.date(2100, 11, 24), model.engine.date(2100, 12, 24), "下个月")
        ] {
            try await prepare(source)
            try press(label)
            model.moveMonth(label == "上个月" ? -1 : 1, animated: true)
            try await Task.sleep(for: .milliseconds(550))
            try assertArrival(target)
        }
    }

    private func verifyMonthNavigation(directory: URL) async throws {
        try await saveSnapshot("navigation-october-light", to: directory)
        guard let model, let view = hostingController?.view, let window = view.window else {
            throw CocoaError(.coderInvalidValue)
        }
        func button(_ label: String) throws -> AnyObject {
            func find(in element: AnyObject) -> AnyObject? {
                if element.accessibilityRole?() == .button, element.accessibilityLabel?() == label { return element }
                for child in element.accessibilityChildren?() ?? [] {
                    if let found = find(in: child as AnyObject) { return found }
                }
                return nil
            }
            guard let found = find(in: view) else {
                fputs("月份导航按钮不可访问：\(label)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            return found
        }
        func click(_ label: String) async throws {
            guard let frame = try button(label).accessibilityFrame?(), !frame.isEmpty else {
                throw CocoaError(.coderInvalidValue)
            }
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    throw CocoaError(.coderInvalidValue)
                }
                NSApp.postEvent(event, atStart: false)
            }
            try await Task.sleep(for: .milliseconds(label == "今天" ? 850 : 400))
            try await waitForCalendarTransition()
        }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        defer { panel.behavior = behavior }
        try await click("上个月")
        guard model.selection == model.engine.date(2026, 9, 24) else {
            fputs("上个月按钮未定位到九月。\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        try await click("下个月")
        guard model.selection == model.today else { throw CocoaError(.coderInvalidValue) }
        model.select(model.engine.date(2026, 12, 31))
        defaults.set("dark", forKey: "appearance")
        try await saveSnapshot("navigation-december-dark", to: directory)
        try await click("今天")
        guard model.selection == model.today, model.month == model.engine.monthStart(model.today) else {
            throw CocoaError(.coderInvalidValue)
        }
        for (date, label, name) in [
            (model.engine.date(1901, 1, 1), "上个月", "lower"),
            (model.engine.date(2100, 12, 31), "下个月", "upper")
        ] {
            model.select(date)
            try await saveSnapshot("navigation-\(name)-disabled", to: directory)
            guard try button(label).isAccessibilityEnabled?() == false else { throw CocoaError(.coderInvalidValue) }
            try await click(label)
            guard model.selection == date else { throw CocoaError(.coderInvalidValue) }
        }
        defaults.set("light", forKey: "appearance")
        model.select(model.today)
    }

    private func verifyCalendarGrid(directory: URL) async throws {
        guard let model, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
        presentation.reduceMotionOverride = false
        defer { presentation.reduceMotionOverride = nil; presentation.cancelTransition() }
        var report: [[String: Any]] = []
        func prepared() async throws {
            let began = ProcessInfo.processInfo.systemUptime
            while !presentation.isPreparedForSampling, ProcessInfo.processInfo.systemUptime - began < 2 {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard presentation.isPreparedForSampling else { throw CocoaError(.coderInvalidValue) }
        }
        for (year, month, weekday, offset) in [(2026, 10, 1, 0), (2026, 3, 2, 0), (2021, 2, 2, 0),
                                               (2024, 2, 1, 0), (2026, 10, 1, 130), (2027, 1, 1, 0)] {
            defaults.set(weekday, forKey: "firstWeekday")
            model.select(model.engine.date(year, month, 23))
            try await Task.sleep(for: .milliseconds(150))
            if offset > 0 {
                let table = try calendarTimelineTable()
                guard let scroll = table.enclosingScrollView else { throw CocoaError(.coderInvalidValue) }
                (scroll as? CalendarTimelineScrollView)?.onActivity?()
                scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.contentView.bounds.minY + CGFloat(offset)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(for: .milliseconds(150))
            }
            for intoYear in [true, false] {
                var pressedMonth: NSButton?
                if intoYear {
                    model.openYearOverview()
                } else if year == 2027 {
                    let table = try overviewTable()
                    let row = (year - CalendarEngine.years.lowerBound) * 7 + 1 + (month - 1) / 2
                    guard let pair = table.view(atColumn: 0, row: row, makeIfNecessary: false),
                          let button = pair.subviews.compactMap({ $0 as? NSButton })
                            .first(where: { $0.title == "\(year)年\(month)月" }) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    pressedMonth = button
                    button.highlight(true)
                    guard button.accessibilityPerformPress() else { throw CocoaError(.coderInvalidValue) }
                } else {
                    model.dismissYearLevel()
                }
                defer { pressedMonth?.highlight(false) }
                try await prepared()
                let name = "grid-\(year)-\(month)-\(offset)-\(intoYear ? "out" : "in")"
                var samples: [[String: Double]] = []
                for frame in 0...90 {
                    presentation.sampleGeometry(deltaTime: frame == 0 ? 0 : 1.0 / 120)
                    // 强制走实际绘制，受控时钟不依赖显示器回调。
                    presentation.transitionView?.display()
                    guard let sample = presentation.canvasSample,
                          sample["dateCopies"] == 1, sample["dateCount"] == sample["expectedDateCount"],
                          sample["backgroundCirclePixels"] == 0 else {
                        fputs("日期重复绘制或快照残留红圈：\(name)，采样=\(String(describing: presentation.canvasSample))\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                    samples.append(sample)
                    if [0, 12, 24, 36, 60, 90].contains(frame) {
                        try saveViewSnapshot(presentation.view, name: name + "-\(frame)", to: directory)
                    }
                }
                if !intoYear, let end = samples.last, end["endError"]! >= 0.2 {
                    fputs("日期交接误差过大：\(name)，\(end["endError"]!)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                presentation.finishGeometrySampling()
                report.append(["name": name, "frames": samples, "drawingMS": presentation.drawingMilliseconds])
                try saveViewSnapshot(presentation.view, name: name + "-end", to: directory)
            }
        }
        model.select(model.engine.date(2026, 10, 23))
        try await Task.sleep(for: .milliseconds(150))
        model.openYearOverview()
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.10)
        var reversals: [[String: Any]] = []
        for (name, action) in [
            ("year-to-month", { model.dismissYearLevel() }),
            ("month-to-year", { model.openYearOverview() }),
            ("year-to-settings", { model.showingSettings = true }),
            ("settings-to-year", { model.showingSettings = false }),
            ("year-to-month-again", { model.dismissYearLevel() })
        ] {
            let count = presentation.retargetCount
            action()
            try await prepared()
            presentation.sampleGeometry(deltaTime: 0)
            guard presentation.retargetCount == count + 1,
                  presentation.retargetPositionError < 0.001, presentation.retargetVelocityError < 0.001 else {
                fputs("受控时间的画布重定向不连续：\(name)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            reversals.append(["name": name, "positionError": presentation.retargetPositionError,
                              "velocityError": presentation.retargetVelocityError])
            presentation.sampleGeometry(deltaTime: 0.06)
            try saveViewSnapshot(presentation.view, name: "grid-redirect-" + name, to: directory)
        }
        presentation.sampleGeometry(deltaTime: 1)
        presentation.finishGeometrySampling()
        presentation.reduceMotionOverride = true
        model.openYearOverview()
        try await prepared()
        let reducedCard = presentation.movingCardFrame
        presentation.sampleGeometry(deltaTime: 0.06)
        guard presentation.canvasSample == nil, presentation.movingCardFrame == reducedCard else {
            throw CocoaError(.coderInvalidValue)
        }
        presentation.sampleGeometry(deltaTime: 0.06)
        presentation.finishGeometrySampling()
        try JSONSerialization.data(withJSONObject: reversals, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("grid-retargeting.json"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("grid-geometry.json"))
        for blur in [false, true] {
            defaults.set(blur, forKey: "blurEnabled")
            for appearance in ["light", "dark"] {
                defaults.set(appearance, forKey: "appearance")
                try await saveSnapshot("grid-caption-\(blur)-\(appearance)", to: directory)
                try await saveOverviewMonthFeedback(year: 2026, month: 10,
                    name: "grid-caption-\(blur)-\(appearance)", to: directory)
            }
        }
    }

    private func verifyCalendarZoom(directory: URL) async throws {
        guard let model, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
        let behavior = panel.behavior
        panel.behavior = .applicationDefined
        presentation.reduceMotionOverride = false
        defer { panel.behavior = behavior; presentation.reduceMotionOverride = nil }
        var report: [[String: Any]] = []
        func sample(_ name: String, moving: Bool = true, matched: Bool = true, expectedMonth: Int? = nil) async throws {
            var positions: [Double] = []
            var heights: [Double] = []
            var cardHeights: [Double] = []
            var timing: [[String: Double]] = []
            var canvases: [[String: Double]] = []
            var savedStages: Set<Int> = []
            guard let shell = presentation.shell else { throw CocoaError(.coderInvalidValue) }
            let material = presentation.material
            var chrome: [[String: Double]] = []
            func checkChrome() throws {
                func visible(_ view: NSView) -> Bool {
                    var current: NSView? = view
                    while let node = current {
                        if node.isHidden || node.alphaValue < 0.999 { return false }
                        current = node.superview
                    }
                    return view.window != nil
                }
                let blur = defaults.object(forKey: "blurEnabled") as? Bool ?? true
                guard presentation.shell === shell, presentation.material === material,
                      visible(shell.header.superview!), visible(shell.footer.superview!), shell.chromeCoverage >= 0.999,
                      material.superview === presentation.view, material.isHidden == !blur,
                      material.frame == presentation.view.bounds,
                      !blur || visible(material) else {
                    fputs("月年切换重建或隐藏了常驻上下栏／背景：\(name)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                if presentation.isTransitioning, presentation.progress > 0,
                   let card = presentation.movingCardFrame {
                    let footerFrame = presentation.view.convert(shell.footer.bounds, from: shell.footer)
                    guard abs(footerFrame.minY - card.maxY) < 1,
                          shell.header.visibleRect.height > 20, shell.footer.visibleRect.height > 10 else {
                        fputs("月年过渡上下栏被裁空或底栏脱离卡片：\(name)\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                }
                chrome.append(["progress": presentation.progress,
                               "headerAlpha": shell.header.alphaValue,
                               "footerAlpha": shell.footer.alphaValue,
                               "hostAlpha": presentation.host.view.alphaValue])
            }
            try checkChrome()
            var savedMiddle = false
            let began = ProcessInfo.processInfo.systemUptime
            while presentation.isTransitioning, ProcessInfo.processInfo.systemUptime - began < 2 {
                try await Task.sleep(for: .milliseconds(16))
                try checkChrome()
                if presentation.isTransitioning, let card = presentation.movingCardFrame, presentation.progress > 0 {
                    if let frame = presentation.movingDayFrame { positions.append(frame.midX + frame.midY) }
                    if moving, let canvas = presentation.canvasSample {
                        canvases.append(canvas)
                        if let expectedMonth, canvas["focusMonth"] != Double(expectedMonth) {
                            fputs("缩放焦点未采用点击时的优势月份：\(name)，期望=\(expectedMonth)，实际=\(canvas["focusMonth"] ?? -1)\n", stderr)
                            throw CocoaError(.coderInvalidValue)
                        }
                        let scale = canvas["scale"]!
                        let ratios = [canvas["focusWidth"]! / canvas["baseFocusWidth"]!,
                                      canvas["focusHeight"]! / canvas["baseFocusHeight"]!,
                                      canvas["neighborWidth"]! / canvas["baseNeighborWidth"]!,
                                      canvas["neighborHeight"]! / canvas["baseNeighborHeight"]!]
                        let dx = canvas["neighborX"]! - canvas["focusX"]!
                        let dy = canvas["neighborY"]! - canvas["focusY"]!
                        guard ratios.allSatisfy({ abs($0 - scale) < 0.001 }), canvas["vector"] == 1,
                              canvas["dateCopies"] == 1, canvas["backgroundCirclePixels"] == 0,
                              canvas["dateCount"] == canvas["expectedDateCount"],
                              abs(dx - (canvas["baseNeighborX"]! - canvas["baseFocusX"]!) * scale) < 0.01,
                              abs(dy - (canvas["baseNeighborY"]! - canvas["baseFocusY"]!) * scale) < 0.01 else {
                            fputs("画布变换或日期单份绘制异常：\(name)，日期份数=\(canvas["dateCopies"] ?? -1)，背景红圈像素=\(canvas["backgroundCirclePixels"] ?? -1)\n", stderr)
                            throw CocoaError(.coderInvalidValue)
                        }
                        for stage in [20, 60, 90] where presentation.progress >= Double(stage) / 100 && !savedStages.contains(stage) {
                            try saveViewSnapshot(presentation.view, name: name + "-canvas-\(stage)", to: directory)
                            savedStages.insert(stage)
                        }
                    }
                    heights.append(panel.contentSize.height)
                    cardHeights.append(card.height)
                    timing.append(["time": presentation.elapsedFraction, "progress": presentation.progress,
                                   "seconds": presentation.motionSeconds, "outgoing": presentation.outgoingOpacity,
                                   "incoming": presentation.incomingOpacity, "chromeCoverage": shell.chromeCoverage])
                    if !savedMiddle, presentation.progress > 0.35 {
                        try saveViewSnapshot(presentation.view, name: name + "-middle", to: directory)
                        savedMiddle = true
                    }
                    guard presentation.hasActiveFrameDriver,
                          (presentation.matchedDayCount > 0) == matched else {
                        fputs("动画端点或驱动不可用：\(name)，匹配=\(presentation.matchedDayCount)，驱动=\(presentation.hasActiveFrameDriver)\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                }
            }
            try checkChrome()
            guard cardHeights.count >= 3, (!matched || positions.count >= 3), savedMiddle, !presentation.isTransitioning,
                  presentation.transitionView == nil, hostingController?.view.alphaValue == 1 else {
                fputs("月年过渡没有连续中间帧或未清理：\(name)，采样=\(positions.count)，进度=\(presentation.progress)，活动=\(presentation.isTransitioning)，中间帧=\(savedMiddle)，准备=\(presentation.preparationPhases)，驱动=\(presentation.hasActiveFrameDriver)，回调=\(presentation.driverCallbackCount)，屏幕=\(String(describing: presentation.view.window?.screen))，透明度=\(hostingController?.view.alphaValue ?? -1)，尺寸=\(panel.contentSize)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            if moving {
                try validatePresentationTiming(timing, name: name)
                let settling = timing.filter { $0["seconds"]! >= 0.30 && $0["seconds"]! <= 0.36 }
                guard !settling.isEmpty, settling.allSatisfy({ $0["progress"]! >= 0.98 }),
                      timing.allSatisfy({ $0["seconds"]! <= 0.60 }) else {
                    fputs("月年过渡未及时接近终点或收尾过长：\(name)，末帧时间=\(timing.last?["seconds"] ?? 0)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                let scales = canvases.compactMap { $0["scale"] }
                guard scales.count >= 3, (scales.max() ?? 0) - (scales.min() ?? 0) > 0.5,
                      canvases.contains(where: { $0["detail"]! > 0 && $0["detail"]! < 1 }),
                      model.showingYearOverview ? canvases.last!["detail"]! < 0.05 : canvases.last!["detail"]! > 0.95 else {
                    fputs("整张画布缺少缩放或月份详情交接：\(name)，比例=\(scales)，详情=\(canvases.compactMap { $0["detail"] })\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                if !model.showingYearOverview {
                    // 异步轮询可能漏掉最后一次刷新，交接误差在移除动画层的边界测量。
                    guard let end = canvases.last, end["layout"]! > 0.99,
                          let error = presentation.handoffDateError, error < 0.2 else {
                        fputs("日期网格交接到月视图时仍有位置误差：\(name)，交接误差=\(String(describing: presentation.handoffDateError))，末次采样=\(String(describing: canvases.last))\n", stderr)
                        throw CocoaError(.coderInvalidValue)
                    }
                }
                guard let low = positions.min(), let high = positions.max(), high - low > 5 else {
                    fputs("月年过渡的日期没有移动：\(name)，位置=\(positions)，时序=\(timing)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                guard let low = cardHeights.min(), let high = cardHeights.max(), high - low > 20,
                      Set(cardHeights.map { Int($0 * 2) }).count >= 3 else {
                    fputs("白色容器没有连续改变尺寸：\(name)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
            } else {
                guard positions.allSatisfy({ abs($0 - (positions.first ?? $0)) < 0.5 }),
                      cardHeights.allSatisfy({ abs($0 - cardHeights[0]) < 0.5 }) else {
                    fputs("短淡化模式仍发生日期或容器缩放：\(name)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
            }
            let callbacks = presentation.driverCallbackCount
            try await Task.sleep(for: .milliseconds(40))
            let timestamps = presentation.displayTimestamps
            guard !presentation.hasActiveFrameDriver, presentation.driverCallbackCount == callbacks,
                  timestamps.count >= 3, zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 < $1 }) else {
                fputs("月年过渡缺少显示刷新回调或结束后仍有回调：\(name)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            guard shell.content.alphaValue == 1, shell.transitionCard == nil else {
                fputs("月年切换后正文或底栏位置未恢复：\(name)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            report.append(["name": name, "positions": positions, "heights": heights,
                           "cardHeights": cardHeights, "timing": timing, "chrome": chrome, "canvas": canvases,
                           "handoffDateError": presentation.handoffDateError as Any? ?? NSNull(),
                           "displayTimestamps": timestamps,
                           "preparationMS": presentation.preparationMilliseconds,
                           "preparationPhases": presentation.preparationPhases,
                           "frameMS": presentation.frameMilliseconds,
                           "drawingMS": presentation.drawingMilliseconds])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("zoom-motion.json"))
            try saveViewSnapshot(presentation.view, name: name + "-end", to: directory)
        }
        for (year, month, day, weekday) in [(2026, 10, 24, 1), (2026, 3, 24, 2),
                                           (2021, 2, 14, 2), (2024, 2, 29, 1),
                                           (1901, 1, 1, 1), (2100, 12, 31, 2)] {
            defaults.set(weekday, forKey: "firstWeekday")
            model.select(model.engine.date(year, month, day))
            try await Task.sleep(for: .milliseconds(450))
            try await waitForCalendarTransition()
            guard let host = hostingController,
                  abs(panel.contentSize.height - host.view.fittingSize.height) < 1 else {
                fputs("弹窗没有跟随月份详情的实际尺寸：\(panel.contentSize)，预期=\(hostingController?.view.fittingSize ?? .zero)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            try saveViewSnapshot(presentation.view, name: "zoom-\(year)-\(month)-start", to: directory)
            let selection = model.selection
            model.openYearOverview()
            try await sample("zoom-\(year)-\(month)-out")
            guard model.selection == selection, model.showingYearOverview else { throw CocoaError(.coderInvalidValue) }
            let table = try overviewTable()
            let row = (year - CalendarEngine.years.lowerBound) * 7 + 1 + (month - 1) / 2
            guard let pair = table.view(atColumn: 0, row: row, makeIfNecessary: false),
                  let button = pair.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "\(year)年\(month)月" }),
                  button.accessibilityPerformPress() else { throw CocoaError(.coderInvalidValue) }
            try await sample("zoom-\(year)-\(month)-in")
            guard model.selection == selection, !model.showingYearOverview else { throw CocoaError(.coderInvalidValue) }
        }
        for (name, year, month, weekday, bias, expected) in [
            ("previous-more", 2026, 10, 1, -1.0, 202610),
            ("equal-next", 2026, 10, 1, 0.0, 202611),
            ("next-more", 2026, 10, 1, 1.0, 202611),
            ("last-week", 2026, 10, 1, 63.0, 202611),
            ("cross-year", 2026, 12, 1, 63.0, 202701),
            ("four-weeks-equal", 2021, 2, 1, 0.0, 202103),
            ("leap-year", 2024, 2, 2, 63.0, 202403)
        ] {
            defaults.set(weekday, forKey: "firstWeekday")
            model.select(model.engine.date(year, month, 24))
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
            let selection = model.selection
            let table = try calendarTimelineTable()
            guard let scroll = table.enclosingScrollView else { throw CocoaError(.coderInvalidValue) }
            let timeline = model.calendarTimeline(firstWeekday: weekday)
            let nextMonth = model.engine.addingMonths(1, to: model.month)
            let boundary = table.rect(ofRow: timeline.weekRow(containing: nextMonth) - 1).minY
            (scroll as? CalendarTimelineScrollView)?.onActivity?()
            let position = boundary - table.visibleRect.height / 2 + bias
            scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
            scroll.reflectScrolledClipView(scroll.contentView)
            // 不等待滚动通知：焦点与返回位置必须在点击这一刻读取实际视口。
            model.openYearOverview()
            let expectedDate = model.engine.date(expected / 100, expected % 100, 1)
            guard model.overviewFocusMonth == expectedDate,
                  model.overviewTarget == expected / 100 * 100 + ((expected % 100 - 1) / 2 * 2 + 1),
                  model.selection == selection, let viewport = model.calendarViewport else {
                fputs("跨月焦点或年概览定位错误：\(name)，期望=\(expected)，实际=\(String(describing: model.overviewFocusMonth))\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            try await sample("zoom-focus-" + name + "-out", expectedMonth: expected)
            model.dismissYearLevel()
            try await sample("zoom-focus-" + name + "-return", expectedMonth: expected)
            let restored = try calendarTimelineTable()
            let restoredRow = timeline.weekRow(containing: viewport.date, inMonth: viewport.month)
            guard abs(restored.visibleRect.minY - restored.rect(ofRow: restoredRow).minY - viewport.offset) < 1,
                  model.selection == selection else {
                fputs("跨月缩放未恢复原可见周及其偏移：\(name)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            if name == "last-week" {
                model.openYearOverview()
                try await sample("zoom-focus-reopen-out", expectedMonth: expected)
                let overview = try overviewTable()
                let targetMonth = 12
                let row = (year - CalendarEngine.years.lowerBound) * 7 + 1 + (targetMonth - 1) / 2
                guard let pair = overview.view(atColumn: 0, row: row, makeIfNecessary: false),
                      let button = pair.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "\(year)年\(targetMonth)月" }),
                      button.accessibilityPerformPress() else { throw CocoaError(.coderInvalidValue) }
                try await sample("zoom-focus-explicit-month-in", expectedMonth: year * 100 + targetMonth)
                guard model.overviewFocusMonth == nil, model.calendarSnappedMonth == model.month else {
                    throw CocoaError(.coderInvalidValue)
                }
            }
        }
        defaults.set(1, forKey: "firstWeekday")
        model.select(model.engine.date(2026, 10, 24))
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        let selection = model.selection
        for interruption in ["preparation", "reverse", "settings", "close"] {
            model.openYearOverview()
            if interruption != "preparation" { try await Task.sleep(for: .milliseconds(60)) }
            switch interruption {
            case "preparation": model.dismissYearLevel()
            case "reverse":
                guard let window = hostingController?.view.window,
                      let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                          isARepeat: false, keyCode: 53) else { throw CocoaError(.coderInvalidValue) }
                NSApp.postEvent(escape, atStart: false)
            case "settings": model.showingSettings = true
            default: panel.performClose(nil)
            }
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
            let callbacks = presentation.driverCallbackCount
            try await Task.sleep(for: .milliseconds(40))
            guard !presentation.isTransitioning, presentation.transitionView == nil,
                  !presentation.hasActiveFrameDriver, presentation.driverCallbackCount == callbacks,
                  hostingController?.view.alphaValue == 1, model.selection == selection,
                  !["preparation", "reverse"].contains(interruption) || !model.showingYearOverview else {
                fputs("月年过渡中断后残留遮罩或覆盖选择：\(interruption)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            if interruption == "close" { showPanel() }
            model.showingSettings = false
            model.select(selection)
            try await Task.sleep(for: .milliseconds(400))
            try await waitForCalendarTransition()
        }
        presentation.reduceMotionOverride = true
        model.openYearOverview()
        try await sample("zoom-reduced-motion", moving: false)
        presentation.reduceMotionOverride = false
        model.yearDraft = "2048"
        model.jumpToOverviewYear()
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        model.dismissYearLevel()
        try await sample("zoom-offscreen-month", moving: false, matched: false)
        for appearance in ["light", "dark"] {
            for blur in [false, true] {
                defaults.set(appearance, forKey: "appearance")
                defaults.set(blur, forKey: "blurEnabled")
                try await Task.sleep(for: .milliseconds(300))
                try await waitForCalendarTransition()
                guard hostingController?.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                        == (appearance == "dark" ? .darkAqua : .aqua) else {
                    fputs("动画外观未跟随偏好：\(appearance)，应用=\(String(describing: NSApp.appearance))，窗口=\(String(describing: hostingController?.view.window?.appearance))，视图=\(String(describing: hostingController?.view.appearance))\n", stderr)
                    throw CocoaError(.coderInvalidValue)
                }
                model.openYearOverview()
                try await sample("zoom-\(appearance)-\(blur ? "blur" : "solid")-out")
                model.dismissYearLevel()
                try await sample("zoom-\(appearance)-\(blur ? "blur" : "solid")-in")
            }
        }
        try await verifyCalendarRetargeting(directory: directory)
    }

    private func verifyCalendarRetargeting(directory: URL) async throws {
        guard let model, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
        model.showingSettings = false
        model.showingYearOverview = false
        try await waitForCalendarTransition()
        model.select(model.engine.date(2026, 10, 24))
        try await Task.sleep(for: .milliseconds(100))
        var report: [[String: Any]] = []
        func waitForMovement() async throws {
            let began = ProcessInfo.processInfo.systemUptime
            while (!presentation.hasActiveFrameDriver || presentation.motionSeconds < 0.06),
                  ProcessInfo.processInfo.systemUptime - began < 2 {
                try await Task.sleep(for: .milliseconds(4))
            }
            guard presentation.isTransitioning, presentation.hasActiveFrameDriver,
                  presentation.motionSeconds >= 0.06 else { throw CocoaError(.coderInvalidValue) }
        }
        func redirect(_ name: String, action: () -> Void) async throws {
            try await waitForMovement()
            let count = presentation.retargetCount
            let card = presentation.movingCardFrame
            let height = panel.contentSize.height
            action()
            guard presentation.isTransitioning, presentation.movingCardFrame == card,
                  abs(panel.contentSize.height - height) < 0.1 else {
                fputs("重定向在准备终点前跳变：\(name)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            let began = ProcessInfo.processInfo.systemUptime
            while presentation.retargetCount == count, ProcessInfo.processInfo.systemUptime - began < 2 {
                try await Task.sleep(for: .milliseconds(4))
            }
            guard presentation.retargetCount == count + 1, presentation.hasActiveFrameDriver,
                  presentation.retargetPositionError < 0.001, presentation.retargetVelocityError < 0.001 else {
                fputs("重定向丢失当前位置或速度：\(name)，位置=\(presentation.retargetPositionError)，速度=\(presentation.retargetVelocityError)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            report.append(["name": name, "positionError": presentation.retargetPositionError,
                           "velocityError": presentation.retargetVelocityError,
                           "preparationMS": presentation.preparationMilliseconds])
        }
        model.openYearOverview()
        try await redirect("year-to-month") { model.dismissYearLevel() }
        try await redirect("month-to-year") { model.openYearOverview() }
        try await redirect("year-to-settings") { model.showingSettings = true }
        try await redirect("settings-to-year") { model.showingSettings = false }
        try await redirect("year-to-month-again") { model.dismissYearLevel() }
        try await waitForCalendarTransition()
        guard !model.showingYearOverview, !model.showingSettings else { throw CocoaError(.coderInvalidValue) }
        model.showingSettings = true
        try await redirect("settings-to-month") { model.showingSettings = false }
        try await redirect("month-to-settings") { model.showingSettings = true }
        try await waitForCalendarTransition()
        model.showingSettings = false
        try await waitForCalendarTransition()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("motion-retargeting.json"))
    }

    private func waitForCalendarTransition() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        while presentationController?.isTransitioning == true,
              ProcessInfo.processInfo.systemUptime - began < 3 {
            try await Task.sleep(for: .milliseconds(8))
        }
        guard presentationController?.isTransitioning != true else {
            fputs("日历过渡未在期限内收敛。\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func validatePresentationTiming(_ frames: [[String: Double]], name: String) throws {
        let early = frames.filter { $0["time"]! >= 0.1 && $0["time"]! <= 0.3 }
        let crossing = frames.filter { $0["seconds"]! >= 0.03 && $0["seconds"]! <= 0.12 }
        guard !early.isEmpty, early.allSatisfy({ $0["progress"]! <= 2 * $0["time"]! + 0.015 }),
              !crossing.isEmpty, crossing.allSatisfy({ $0["outgoing"]! > 0.2 && $0["incoming"]! > 0 }),
              frames.allSatisfy({ abs($0["outgoing"]! + $0["incoming"]! - 1) < 0.001 && $0["chromeCoverage"]! >= 0.999 }),
              frames.contains(where: { $0["seconds"]! >= 0.2 && $0["progress"]! < 0.99 }) else {
            fputs("动画起步过急、正文淡化不连续或缺少自然收尾：\(name)\n", stderr)
            if let data = try? JSONSerialization.data(withJSONObject: frames, options: [.sortedKeys]),
               let samples = String(data: data, encoding: .utf8) {
                fputs("动画时序采样：\(samples)\n", stderr)
            }
            throw CocoaError(.coderInvalidValue)
        }
    }

    private func saveSnapshot(_ name: String, to directory: URL) async throws {
        try await Task.sleep(for: .milliseconds(400))
        try await waitForCalendarTransition()
        guard let view = presentationController?.view else { throw CocoaError(.coderInvalidValue) }
        try saveViewSnapshot(view, name: name, to: directory)
    }

    private func saveViewSnapshot(_ view: NSView, name: String, to directory: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.coderInvalidValue)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.coderInvalidValue)
        }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
    #endif
}
