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
            let view = CalendarView(model: model, updateMenuBar: { [weak self] in self?.refresh() }) {
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
            let host = NSHostingController(rootView: root)
            host.sizingOptions = [.preferredContentSize]
            hostingController = host
            popover.contentViewController = host
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
        removeKeyboardMonitor()
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            if ProcessInfo.processInfo.arguments.contains("--scroll-benchmark") {
                try await benchmarkOverviewScroll(directory: directory)
                NSApp.terminate(nil)
                return
            }
            try await saveSnapshot("light-october", to: directory)
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
            defaults.set("light", forKey: "appearance")
            popover.performClose(nil)
            guard !popover.isShown, keyboardMonitor == nil else { throw CocoaError(.coderInvalidValue) }
            try "真实状态栏弹窗、外观与节日显示快照、跨年选择、日期下界、关闭清理通过。\n"
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
        model.select(original)
        defaults.set("light", forKey: "appearance")
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
            fputs("年概览定位失败：\(year)年\(month)月\n", stderr)
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

    private func saveSnapshot(_ name: String, to directory: URL) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard let view = hostingController?.view else { throw CocoaError(.coderInvalidValue) }
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
