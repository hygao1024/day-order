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
            let model = CalendarModel(engine: try CalendarEngine())
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
        model?.monthPickerYear = ""
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
                    if model.showingMonthPicker { model.showingMonthPicker = false }
                    else if model.showingSettings { model.showingSettings = false }
                    else { self.popover.performClose(nil) }
                    return true
                }
                guard !model.showingSettings, !model.showingMonthPicker,
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
            try await saveSnapshot("light-october", to: directory)
            try await verifyMonthPicker(directory: directory)
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
            try await verifyMenuBar(directory: directory, defaults: defaults, domain: domain)
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
        for screen in ["month", "settings", "month-picker"] {
            model.select(model.engine.date(2048, 12, 23))
            if screen == "settings" { model.showingSettings = true }
            if screen == "month-picker" {
                model.openMonthPicker()
                model.monthPickerYear = "无效年份"
            }
            model.today = model.engine.addingDays(-1, to: model.engine.today())
            popover.performClose(nil)
            togglePopover()
            let today = model.engine.today()
            guard popover.isShown, !model.showingSettings, !model.showingMonthPicker,
                  model.monthPickerYear.isEmpty, model.today == today,
                  model.selection == model.engine.clamped(today),
                  model.month == model.engine.monthStart(model.selection),
                  preferences.isEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain) ?? [:])) else {
                fputs("重新打开未回到今日：\(screen)\n", stderr)
                throw CocoaError(.coderInvalidValue)
            }
        }
        try await saveSnapshot("reopened-today", to: directory)
    }

    private func verifyMonthPicker(directory: URL) async throws {
        guard let model else { throw CocoaError(.coderInvalidValue) }
        let original = model.selection
        // 自动化宿主可能抢走焦点；键盘验证期间固定浮层，避免外部失焦关闭干扰 Esc 结果。
        let behavior = popover.behavior
        popover.behavior = .applicationDefined
        defer { popover.behavior = behavior }
        showPopover()
        model.select(original)
        model.openMonthPicker()
        guard model.monthPickerYear == "2026" else { throw CocoaError(.coderInvalidValue) }
        try await saveSnapshot("month-picker", to: directory)
        model.monthPickerYear = "2048"
        try await saveSnapshot("month-picker-edited", to: directory)
        guard let window = hostingController?.view.window,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                  isARepeat: false, keyCode: 53) else { throw CocoaError(.coderInvalidValue) }
        NSApp.postEvent(escape, atStart: false)
        try await Task.sleep(for: .milliseconds(400))
        guard !model.showingMonthPicker, popover.isShown, model.selection == original else {
            fputs("取消验证失败：picker=\(model.showingMonthPicker), popover=\(popover.isShown), selection=\(model.selection == original), monitor=\(keyboardMonitor != nil)\n", stderr)
            throw CocoaError(.coderInvalidValue)
        }
        model.openMonthPicker()
        model.monthPickerYear = "2048"
        model.jumpToMonth(12, year: 2048)
        guard model.selection == model.engine.date(2048, 12, 23), !model.showingMonthPicker else {
            throw CocoaError(.coderInvalidValue)
        }
        try await saveSnapshot("month-jump-result", to: directory)
        model.openMonthPicker()
        for invalid in ["", "abc", "1900", "2101"] {
            model.monthPickerYear = invalid
            guard model.validMonthPickerYear == nil else { throw CocoaError(.coderInvalidValue) }
        }
        try await saveSnapshot("month-picker-invalid", to: directory)
        let beforeInvalidJump = model.selection
        for (year, month) in [(1900, 1), (2101, 1), (2026, 0), (2026, 13)] {
            model.jumpToMonth(month, year: year)
            guard model.selection == beforeInvalidJump, model.showingMonthPicker else {
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
        model.openMonthPicker()
        defaults.set("dark", forKey: "appearance")
        try await saveSnapshot("month-picker-upper-bound-dark", to: directory)
        model.jumpToMonth(1, year: 1901)
        model.openMonthPicker()
        try await saveSnapshot("month-picker-lower-bound-dark", to: directory)
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
