import AppKit
import DayOrderCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var defaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var model: CalendarModel?
    private var refreshTimer: Timer?
    private var keyboardMonitor: Any?
    private var hostingController: NSHostingController<AnyView>?
    private var presentationController: CalendarPresentationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            #if DEBUG
            let holidayCacheDirectory = smokeDirectory?.appendingPathComponent("holiday-cache", isDirectory: true)
            #else
            let holidayCacheDirectory: URL? = nil
            #endif
            let model = CalendarModel(engine: try CalendarEngine(), holidayCacheDirectory: holidayCacheDirectory)
            self.model = model
            let view = CalendarView(model: model, updateMenuBar: { [weak self] in self?.refresh() },
                                    updatePopoverAppearance: { [weak self] in self?.popover.appearance = $0 }) {
                [weak self] in self?.popover.performClose(nil)
            }
            var root = AnyView(view)
            #if DEBUG
            if let directory = smokeDirectory {
                let domain = "com.dayorder.smoke.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: domain)!
                self.defaults = defaults
                root = AnyView(view.defaultAppStorage(defaults))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.runSmokeTest(directory: directory, defaults: defaults, domain: domain)
                }
            }
            #endif
            let host = CalendarHostingController(rootView: root)
            hostingController = host
            let presentation = CalendarPresentationController(host: host, model: model, defaults: defaults)
            presentationController = presentation
            popover.contentViewController = presentation
            popover.behavior = .transient
            popover.animates = false
            popover.delegate = self

            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.setAccessibilityLabel("日序日历")
            refresh()

            refreshTimer = Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(refresh),
                                                userInfo: nil, repeats: true)
            refreshTimer?.tolerance = 5
            for name in [NSNotification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                         NSNotification.Name("NSSystemClockDidChangeNotification")] {
                NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh),
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

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        refresh()
        model?.showingSettings = false
        model?.yearDraft = ""
        model?.goToToday()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.popover.isShown, let model = self.model,
                      event.window == self.popover.contentViewController?.view.window else { return false }
                if event.keyCode == 53 {
                    if model.showingYearOverview { model.dismissYearLevel() }
                    else if model.showingSettings { model.showingSettings = false }
                    else { self.popover.performClose(nil) }
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

    func popoverDidClose(_ notification: Notification) {
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
        presentationController?.cancelTransition()
        model?.cancelHolidayUpdate()
        refreshTimer?.invalidate()
        removeKeyboardMonitor()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
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
            model.today = model.engine.date(2026, 10, 23)
            model.select(model.today)
            defaults.set("light", forKey: "appearance")
            showPopover()
            // showPopover 会刷新真实日期；快照随后固定时钟，使用同一生产视图。
            model.today = model.engine.date(2026, 10, 23)
            model.select(model.today)
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
            if ProcessInfo.processInfo.arguments.contains("--today-scroll-smoke") {
                try await verifyTodayScroll(directory: directory)
                try "返回今天的连续位移、终点与取消验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--month-snap-smoke") {
                try await verifyMonthSnapping(directory: directory)
                defaults.set(1, forKey: "firstWeekday")
                model.today = model.engine.date(2026, 10, 24)
                model.select(model.today)
                for blur in [false, true] {
                    defaults.set(blur, forKey: "blurEnabled")
                    for appearance in ["light", "dark"] {
                        defaults.set(appearance, forKey: "appearance")
                        try await saveSnapshot("rounded-\(blur ? "blur" : "solid")-\(appearance)", to: directory)
                    }
                }
                try "月初吸附、惯性等待、中途取消、四至六周完整显示、返回恢复与边界验证通过。\n"
                    .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
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
            popover.performClose(nil)
            guard !popover.isShown, keyboardMonitor == nil else { throw CocoaError(.coderInvalidValue) }
            try "真实状态栏弹窗、连续周滚动与跨月选择、滚动位置恢复、辅助功能动作、外观与节日快照、年概览导航、日期边界、关闭清理通过。\n"
                .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        } catch {
            fputs("日序冒烟验证失败：\(error)\n", stderr)
            exit(1)
        }
    }

    private func verifyReopen(directory: URL, domain: String) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
        let preferences = NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:])
        for screen in ["month", "settings", "year-overview"] {
            model.select(model.engine.date(2048, 12, 23))
            if screen == "settings" { model.showingSettings = true }
            if screen == "year-overview" {
                model.openYearOverview()
                model.yearDraft = "无效年份"
            }
            model.today = model.engine.addingDays(-1, to: model.engine.today())
            popover.performClose(nil)
            togglePopover()
            let today = model.engine.today()
            guard popover.isShown, !model.showingSettings, !model.showingYearOverview,
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
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
        showPopover()
        model.select(original)
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
        guard !model.showingYearEntry, model.showingYearOverview, model.selection == original else {
            throw CocoaError(.coderInvalidValue)
        }
        NSApp.postEvent(escape, atStart: false)
        try await Task.sleep(for: .milliseconds(400))
        guard !model.showingYearOverview, popover.isShown, model.selection == original else {
            fputs("取消验证失败：overview=\(model.showingYearOverview), popover=\(popover.isShown), selection=\(model.selection == original), monitor=\(keyboardMonitor != nil)\n", stderr)
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
        button.highlight(true)
        try await saveSnapshot(name + "-pressed", to: directory)
    }

    private func verifyMenuBar(directory: URL, defaults: UserDefaults, domain: String) async throws {
        guard let model, let button = statusItem?.button else { throw CocoaError(.coderInvalidValue) }
        // 通过同一偏好触发 SwiftUI 的 onChange，验证设置确实即时更新状态栏。
        defaults.set(MenuBarDisplay.dateOnly.rawValue, forKey: "menuBarDisplay")
        defaults.set(MenuBarDateFormat.yearMonthDay.rawValue, forKey: "menuBarDateFormat")
        try await Task.sleep(for: .milliseconds(400))
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
        guard button.title.isEmpty, button.image != nil, button.imagePosition == .imageOnly else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("settings-icon-only", to: directory)
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            try await Task.sleep(for: .milliseconds(400))
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
        guard button.image != nil, button.title == "  " + MenuBarDateFormat.monthDayWeekday.title(for: model.engine.info(for: model.today)) else {
            throw CocoaError(.coderInvalidValue)
        }
        defaults.set(MenuBarDisplay.iconAndDate.rawValue, forKey: "menuBarDisplay")
        defaults.set(MenuBarDateFormat.numericDate.rawValue, forKey: "menuBarDateFormat")
        try await Task.sleep(for: .milliseconds(400))
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
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
        defaults.set(1, forKey: "firstWeekday")
        model.select(model.engine.date(2026, 10, 23))
        try await Task.sleep(for: .milliseconds(400))
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
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
        defaults.set(1, forKey: "firstWeekday")
        model.select(model.engine.date(2026, 10, 24))
        try await Task.sleep(for: .milliseconds(400))
        let table = try calendarTimelineTable()
        guard let scroll = table.enclosingScrollView as? CalendarTimelineScrollView else { throw CocoaError(.coderInvalidValue) }
        let timeline = CalendarTimeline(engine: model.engine, firstWeekday: 1)
        let selection = model.selection
        func wheel(_ delta: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0) throws {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: delta, wheel2: 0, wheel3: 0) else { throw CocoaError(.coderInvalidValue) }
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            guard let event = NSEvent(cgEvent: cg) else { throw CocoaError(.coderInvalidValue) }
            scroll.scrollWheel(with: event)
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
        try assertFullMonth(model.month)
        try wheel(-3, phase: 1)
        position(model.engine.date(2026, 9, 1), offset: -22)
        try await Task.sleep(for: .milliseconds(450))
        guard scroll.gestureActive, model.calendarSnappedMonth == nil else { throw CocoaError(.coderInvalidValue) }
        try wheel(phase: 4)
        try wheel(-1, momentum: 1)
        try await Task.sleep(for: .milliseconds(450))
        guard scroll.gestureActive, model.calendarSnappedMonth == nil else { throw CocoaError(.coderInvalidValue) }
        try wheel(momentum: 3)
        try await Task.sleep(for: .milliseconds(500))
        try assertFullMonth(model.engine.date(2026, 9, 1))
        guard model.selection == selection else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("snap-september-five-weeks", to: directory)

        // 再次滚动立即释放整月布局；停在月中不应被拉回月初。
        try wheel(-4)
        // AppKit 会在后续运行循环应用滚轮位移，待其落定后设置测试锚点。
        try await Task.sleep(for: .milliseconds(100))
        position(model.engine.date(2026, 9, 13), offset: 17)
        try await Task.sleep(for: .milliseconds(500))
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
        try assertFullMonth(model.engine.date(2026, 12, 1))

        // 切换设置拆除列表后，待执行任务不应留下吸附状态。
        try wheel()
        position(model.engine.date(2026, 11, 1), offset: -20)
        try await Task.sleep(for: .milliseconds(50))
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(400))
        guard model.calendarSnappedMonth == nil else {
            fputs("设置打开后仍有吸附状态\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        model.showingSettings = false
        try await Task.sleep(for: .milliseconds(300))

        for (year, month, name) in [(2026, 8, "six-weeks"), (2026, 2, "four-weeks"),
                                    (1901, 1, "lower-bound"), (2100, 12, "upper-bound")] {
            model.select(model.engine.date(year, month, 1))
            try await Task.sleep(for: .milliseconds(300))
            try assertFullMonth(model.month, in: try calendarTimelineTable())
            try await saveSnapshot("snap-" + name, to: directory)
        }
        defaults.set("dark", forKey: "appearance")
        defaults.set(2, forKey: "firstWeekday")
        model.select(model.engine.date(2026, 3, 1))
        try await Task.sleep(for: .milliseconds(300))
        try assertFullMonth(model.month, weekdays: 2, in: try calendarTimelineTable())
        try await saveSnapshot("snap-six-weeks-monday-dark", to: directory)
        model.showingSettings = true
        try await Task.sleep(for: .milliseconds(150))
        model.showingSettings = false
        try await Task.sleep(for: .milliseconds(300))
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
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
        model.openYearOverview()
        try await Task.sleep(for: .milliseconds(500))
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
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
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
            let began = ProcessInfo.processInfo.systemUptime
            try pressToday()
            while ProcessInfo.processInfo.systemUptime - began < 0.8 {
                try await Task.sleep(for: .milliseconds(8))
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
                }
                previousOffset = offset
            }
            guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || samples.count >= 3 else {
                fputs("返回今天缺少连续中间位置，发生了直接跳转\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            guard abs(table.visibleRect.minY - table.rect(ofRow: targetRow).minY) < 1, model.selection == model.today,
                  model.calendarSnappedMonth == model.engine.monthStart(model.today) else {
                fputs("返回今天未停在完整当月或未选中今天：来源=\(year)-\(month)，位置=\(table.visibleRect.minY)，初始目标=\(target)，当前目标=\(table.rect(ofRow: targetRow).minY)，选择=\(model.selection)，吸附=\(String(describing: model.calendarSnappedMonth))\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            reports.append(["year": year, "month": month, "startOffset": startOffset, "offsets": samples])
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
                default: popover.performClose(nil)
                }
                try await Task.sleep(for: .milliseconds(650))
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
                    showPopover()
                    model.today = model.engine.date(2026, 10, 23)
                }
            }
        }
        model.goToToday()
        try await saveSnapshot("today-scroll-arrived", to: directory)
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
            try await Task.sleep(for: .milliseconds(400))
        }
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
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

    private func verifyCalendarZoom(directory: URL) async throws {
        guard let model, let presentation = presentationController else { throw CocoaError(.coderInvalidValue) }
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        presentation.reduceMotionOverride = false
        defer { popover.behavior = behavior; presentation.reduceMotionOverride = nil }
        var report: [[String: Any]] = []
        func sample(_ name: String, moving: Bool = true, matched: Bool = true) async throws {
            var positions: [Double] = []
            var heights: [Double] = []
            var cardHeights: [Double] = []
            var timing: [[String: Double]] = []
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
                      visible(shell.header), visible(shell.footer),
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
                    heights.append(popover.contentSize.height)
                    cardHeights.append(card.height)
                    timing.append(["time": presentation.elapsedFraction, "progress": presentation.progress])
                    if !savedMiddle, presentation.progress > 0.35 {
                        try saveViewSnapshot(presentation.view, name: name + "-middle", to: directory)
                        savedMiddle = true
                    }
                    guard presentation.hasActiveFrameDriver,
                          (presentation.matchedDayCount > 0) == matched else { throw CocoaError(.coderInvalidValue) }
                }
            }
            try checkChrome()
            guard cardHeights.count >= 3, (!matched || positions.count >= 3), savedMiddle, !presentation.isTransitioning,
                  presentation.transitionView == nil, hostingController?.view.alphaValue == 1 else {
                fputs("月年过渡没有连续中间帧或未清理：\(name)，采样=\(positions.count)，进度=\(presentation.progress)，活动=\(presentation.isTransitioning)，中间帧=\(savedMiddle)，透明度=\(hostingController?.view.alphaValue ?? -1)，尺寸=\(popover.contentSize)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            if moving {
                guard timing.contains(where: { sample in
                    let time = sample["time"] ?? 1
                    return time >= 0.15 && time <= 0.5 && (sample["progress"] ?? 0) > time + 0.15
                }) else {
                    fputs("月年过渡没有快速起步的缓出阶段：\(name)\n", stderr)
                    throw CocoaError(.coderInvalidValue)
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
                           "cardHeights": cardHeights, "timing": timing, "chrome": chrome,
                           "displayTimestamps": timestamps,
                           "preparationMS": presentation.preparationMilliseconds,
                           "frameMS": presentation.frameMilliseconds,
                           "drawingMS": presentation.drawingMilliseconds])
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("zoom-motion.json"))
            try saveViewSnapshot(presentation.view, name: name + "-end", to: directory)
        }
        for (year, month, day, weekday) in [(2026, 10, 24, 1), (2026, 3, 24, 2),
                                           (1901, 1, 1, 1), (2100, 12, 31, 2)] {
            defaults.set(weekday, forKey: "firstWeekday")
            model.select(model.engine.date(year, month, day))
            try await Task.sleep(for: .milliseconds(450))
            guard let host = hostingController,
                  abs(popover.contentSize.height - host.view.fittingSize.height) < 1 else {
                fputs("弹窗没有跟随月份详情的实际尺寸：\(popover.contentSize)，预期=\(hostingController?.view.fittingSize ?? .zero)\n", stderr)
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
        model.select(model.engine.date(2026, 10, 24))
        try await Task.sleep(for: .milliseconds(400))
        let selection = model.selection
        // 跨月自由停留仅让可见的当前月份日期参与，不改动原滚动位置。
        let table = try calendarTimelineTable()
        guard let scroll = table.enclosingScrollView else { throw CocoaError(.coderInvalidValue) }
        (scroll as? CalendarTimelineScrollView)?.onActivity?()
        let position = scroll.contentView.bounds.minY + 130
        scroll.contentView.scroll(to: NSPoint(x: 0, y: position))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(200))
        guard let viewport = model.calendarViewport else { throw CocoaError(.coderInvalidValue) }
        model.openYearOverview()
        try await sample("zoom-partial-month")
        model.dismissYearLevel()
        try await sample("zoom-return-position")
        let restored = try calendarTimelineTable()
        let timeline = CalendarTimeline(engine: model.engine, firstWeekday: defaults.integer(forKey: "firstWeekday"))
        let restoredRow = timeline.weekRow(containing: viewport.date, inMonth: viewport.month)
        guard abs(restored.visibleRect.minY - restored.rect(ofRow: restoredRow).minY - viewport.offset) < 1,
              model.selection == selection else {
            fputs("月年过渡未恢复原可见周及其偏移\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
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
            default: popover.performClose(nil)
            }
            try await Task.sleep(for: .milliseconds(400))
            let callbacks = presentation.driverCallbackCount
            try await Task.sleep(for: .milliseconds(40))
            guard !presentation.isTransitioning, presentation.transitionView == nil,
                  !presentation.hasActiveFrameDriver, presentation.driverCallbackCount == callbacks,
                  hostingController?.view.alphaValue == 1, model.selection == selection,
                  !["preparation", "reverse"].contains(interruption) || !model.showingYearOverview else {
                fputs("月年过渡中断后残留遮罩或覆盖选择：\(interruption)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
            if interruption == "close" { showPopover() }
            model.showingSettings = false
            model.select(selection)
            try await Task.sleep(for: .milliseconds(400))
        }
        presentation.reduceMotionOverride = true
        model.openYearOverview()
        try await sample("zoom-reduced-motion", moving: false)
        presentation.reduceMotionOverride = false
        model.yearDraft = "2048"
        model.jumpToOverviewYear()
        try await Task.sleep(for: .milliseconds(400))
        model.dismissYearLevel()
        try await sample("zoom-offscreen-month", moving: false, matched: false)
        for appearance in ["light", "dark"] {
            for blur in [false, true] {
                defaults.set(appearance, forKey: "appearance")
                defaults.set(blur, forKey: "blurEnabled")
                try await Task.sleep(for: .milliseconds(300))
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
    }

    private func saveSnapshot(_ name: String, to directory: URL) async throws {
        try await Task.sleep(for: .milliseconds(400))
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
