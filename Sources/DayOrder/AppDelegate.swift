import AppKit
import DayOrderCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
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
            let view = CalendarView(model: model) { [weak self] in self?.popover.performClose(nil) }
            var root = AnyView(view)
            #if DEBUG
            if let directory = smokeDirectory {
                let domain = "com.dayorder.smoke.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName: domain)!
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
            item.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "日序")
            item.button?.imagePosition = .imageLeading
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
        let day = model.engine.info(for: model.today)
        let weekday = ["日", "一", "二", "三", "四", "五", "六"][day.weekday - 1]
        statusItem?.button?.title = "  \(day.month)月\(day.day)日 周\(weekday)"
        statusItem?.button?.toolTip = "日序 · \(day.lunarFull)"
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
                    if model.showingSettings { model.showingSettings = false }
                    else { self.popover.performClose(nil) }
                    return true
                }
                guard !model.showingSettings,
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
            model.showingSettings = false
            model.select(model.engine.date(2026, 12, 31))
            model.moveDay(1)
            guard model.selection == model.engine.date(2027, 1, 1) else { throw CocoaError(.coderInvalidValue) }
            model.select(model.engine.date(1901, 1, 1))
            model.moveDay(-1)
            guard model.selection == model.engine.date(1901, 1, 1), !model.canMoveMonth(-1) else {
                throw CocoaError(.coderInvalidValue)
            }
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

    private func saveSnapshot(_ name: String, to directory: URL) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard let view = hostingController?.view else { throw CocoaError(.coderInvalidValue) }
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
