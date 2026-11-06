#if DEBUG
import DayOrderCore
import Foundation
import AppKit

// 仅替换操作系统边界，快照仍经过生产控制器、索引和日期按钮。
actor SmokeCalendarSource: SystemCalendarSource {
    private var access = CalendarAuthorization.notDetermined
    private var grant = CalendarAuthorization.fullAccess
    private var values: [CalendarEvent] = []
    private var failing = false
    private var delay: Duration = .zero
    private(set) var reads = 0
    private(set) var requests = 0
    private(set) var authorizationChecks = 0
    private var held: CheckedContinuation<[CalendarEvent], Error>?
    private var holdNext = false

    func authorization() -> CalendarAuthorization { authorizationChecks += 1; return access }
    func requestAccess() async throws -> CalendarAuthorization {
        requests += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        access = grant
        return access
    }
    func events(in range: DateInterval) async throws -> [CalendarEvent] {
        reads += 1
        if holdNext {
            holdNext = false
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        if failing { throw CocoaError(.fileReadUnknown) }
        return values
    }
    func configure(access: CalendarAuthorization, grant: CalendarAuthorization = .fullAccess,
                   values: [CalendarEvent] = [], failing: Bool = false, delay: Duration = .zero) {
        self.access = access
        self.grant = grant
        self.values = values
        self.failing = failing
        self.delay = delay
    }
    func holdRead() { holdNext = true }
    var hasHeldRead: Bool { held != nil }
    func finishRead(_ values: [CalendarEvent]) { held?.resume(returning: values); held = nil }
    func counters() -> (checks: Int, requests: Int, reads: Int) { (authorizationChecks, requests, reads) }
}

@MainActor enum CalendarModeSmoke {
    static func verify(events: SystemCalendarEvents, source: SmokeCalendarSource, engine: CalendarEngine,
                       root: NSView, snapshot: (String) async throws -> Void) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "DayOrder.CalendarModeSmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !(await condition()) {
                try require(Date() < deadline, "日程切换状态未在期限内收敛")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let button = descendants(root).compactMap({ $0 as? CalendarEventModeButton }).first else {
            throw CocoaError(.coderInvalidValue)
        }
        let value = CalendarEvent(id: "cycle", title: "周会", start: engine.date(2026, 11, 5),
                                  end: engine.date(2026, 11, 5).addingTimeInterval(3600), allDay: false,
                                  color: .init(red: 0.2, green: 0.48, blue: 0.95))
        await source.configure(access: .fullAccess, values: [value])
        events.update(month: engine.date(2026, 11, 1), engine: engine)
        let initial = await source.counters()
        try require(events.mode == .hidden && initial.checks == 0 && initial.requests == 0 && initial.reads == 0,
                    "默认隐藏不应检测、请求或读取系统日历")
        for expected in [CalendarEventDisplay.detailed, .compact, .dots, .hidden] {
            button.performClick(nil)
            try require(events.mode == expected, "真实按钮未按详细、精简、圆点、隐藏顺序切换")
            try await wait { !events.loading }
            try await snapshot("mode-cycle-" + expected.rawValue)
            try require(button.mode == expected && button.accessibilityLabel()?.contains(expected.title) == true,
                        "切换后的图标与旁白状态不一致")
        }
        let hidden = await source.counters()
        events.update(month: engine.date(2026, 10, 1), engine: engine)
        await Task.detached { NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil) }.value
        try await Task.sleep(for: .milliseconds(220))
        let refreshed = await source.counters()
        try require(refreshed == hidden && events.days.isEmpty, "隐藏时的刷新不应检测日历权限")

        let domain = "com.dayorder.mode-test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        for mode in [CalendarEventDisplay.detailed, .compact, .dots] {
            for access in [CalendarAuthorization.notDetermined, .writeOnly, .fullAccess] {
                let isolated = SmokeCalendarSource()
                await isolated.configure(access: access, values: [value])
                defaults.set(mode.rawValue, forKey: "calendarEventDisplay")
                let controller = SystemCalendarEvents(defaults: defaults, source: isolated)
                defer { controller.stop() }
                controller.update(month: engine.date(2026, 11, 1), engine: engine)
                try await wait { !controller.loading }
                let counts = await isolated.counters()
                try require(counts.checks >= 2 && counts.requests == (access == .fullAccess ? 0 : 1) && counts.reads == 1,
                            "恢复非隐藏模式时未按权限状态检测并申请授权")
                try require(!controller.days.isEmpty && controller.authorization == .fullAccess,
                            "授权后没有加载系统日程")
                if access == .fullAccess {
                    let revision = controller.revision
                    controller.update(month: engine.date(2026, 11, 1), engine: engine)
                    try await wait { !controller.loading }
                    try require(controller.revision == revision, "相同日程重复发布了更新")
                    let renamed = CalendarEvent(id: value.id, title: "修改后的周会", start: value.start,
                        end: value.end, allDay: value.allDay, color: value.color)
                    await isolated.configure(access: .fullAccess, values: [renamed])
                    controller.update(month: engine.date(2026, 11, 1), engine: engine)
                    try await wait { !controller.loading }
                    try require(controller.revision == revision + 1 && controller.days.values.flatMap { $0 }.first?.title == renamed.title,
                                "内容去重阻止了真实事件修改")
                    await isolated.configure(access: .fullAccess)
                    controller.update(month: engine.date(2026, 11, 1), engine: engine)
                    try await wait { !controller.loading }
                    try require(controller.days.isEmpty && controller.revision == revision + 2, "事件移除没有发布更新")
                    controller.update(month: engine.date(2026, 11, 1), engine: engine)
                    try await wait { !controller.loading }
                    try require(controller.revision == revision + 2, "相同空日程重复发布了更新")
                }
                let control = CalendarEventModeButton(events: controller)
                for _ in 0..<4 where controller.mode != .hidden { control.performClick(nil) }
                let before = await isolated.counters()
                controller.update(month: engine.date(2026, 12, 1), engine: engine)
                try await Task.sleep(for: .milliseconds(20))
                let after = await isolated.counters()
                try require(before == after, "切到隐藏后仍检测或申请权限")
            }
        }
        for access in [CalendarAuthorization.denied, .restricted] {
            let isolated = SmokeCalendarSource()
            await isolated.configure(access: access)
            defaults.set(CalendarEventDisplay.hidden.rawValue, forKey: "calendarEventDisplay")
            let controller = SystemCalendarEvents(defaults: defaults, source: isolated)
            defer { controller.stop() }
            controller.update(month: engine.date(2026, 11, 1), engine: engine)
            let control = CalendarEventModeButton(events: controller)
            control.performClick(nil)
            try await wait { !controller.loading }
            let counts = await isolated.counters()
            try require(counts.checks == 1 && counts.requests == 0 && counts.reads == 0 && controller.permissionSettingsPresented,
                        "拒绝或受限时未提供系统设置恢复提示，或越权读取")
            controller.choose(.hidden)
            try require(!controller.permissionSettingsPresented, "隐藏后仍显示权限提示")
            defaults.set(CalendarEventDisplay.dots.rawValue, forKey: "calendarEventDisplay")
            let restored = SystemCalendarEvents(defaults: defaults, source: isolated)
            defer { restored.stop() }
            restored.update(month: engine.date(2026, 11, 1), engine: engine)
            try await wait { !restored.loading }
            try require(restored.permissionSettingsPresented, "恢复非隐藏偏好时缺少拒绝权限的恢复提示")
        }
        let isolated = SmokeCalendarSource()
        defaults.set(CalendarEventDisplay.hidden.rawValue, forKey: "calendarEventDisplay")
        await isolated.configure(access: .notDetermined, values: [value], delay: .milliseconds(120))
        let controller = SystemCalendarEvents(defaults: defaults, source: isolated)
        defer { controller.stop() }
        controller.update(month: engine.date(2026, 11, 1), engine: engine)
        let control = CalendarEventModeButton(events: controller)
        control.performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        control.performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        control.performClick(nil)
        try await wait { !controller.loading }
        try require(await isolated.requests == 1 && controller.mode == .dots, "快速切档重复申请了权限")
        await isolated.holdRead()
        controller.choose(.detailed)
        try await wait { await isolated.hasHeldRead }
        for _ in 0..<3 { control.performClick(nil) }
        let beforeLateResult = await isolated.counters()
        await isolated.finishRead([value])
        try await Task.sleep(for: .milliseconds(60))
        let afterLateResult = await isolated.counters()
        try require(afterLateResult == beforeLateResult && controller.days.isEmpty && !controller.loading,
                    "隐藏后迟到结果仍检测日历权限或恢复日程")
    }
}
#endif
