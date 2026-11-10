#if DEBUG
import AppKit
import QuartzCore

@MainActor enum CalendarRefreshSmoke {
    static func verify(model: CalendarModel, defaults: UserDefaults, root: NSView,
                       presentation: CalendarPresentationController, directory: URL,
                       close: () -> Void, reopen: () -> Void) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition {
                throw NSError(domain: "DayOrder.Refresh", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ message: String, until condition: () -> Bool) async throws {
            let deadline = CACurrentMediaTime() + 3
            while !condition() {
                try require(CACurrentMediaTime() < deadline, message)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func coordinator() throws -> CalendarTimelineView.Coordinator {
            guard let table = descendants(root).compactMap({ $0 as? NSTableView })
                .first(where: { $0.identifier?.rawValue == "calendarTimeline" }),
                  let coordinator = table.delegate as? CalendarTimelineView.Coordinator else {
                throw CocoaError(.coderInvalidValue)
            }
            return coordinator
        }
        func check(_ range: CAFrameRateRange?, enabled: Bool) throws {
            guard let range else { throw CocoaError(.coderInvalidValue) }
            if enabled {
                let maximum = Float(max(1, root.window?.screen?.maximumFramesPerSecond ?? 60))
                try require(range.preferred == maximum && range.maximum == maximum
                            && range.minimum == min(60, maximum), "动画未请求所在屏幕的最高刷新率")
            } else {
                try require(range.preferred == CAFrameRateRange.default.preferred && range.minimum == 0 && range.maximum == 0,
                            "关闭高刷新率后未恢复系统自动调度")
            }
        }
        let key = CalendarRefreshPolicy.preferenceKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        try require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    "本专项需要动画以检查刷新回调；系统减少动态效果已开启")
        var reports: [[String: Any]] = []
        for enabled in [false, true] {
            defaults.set(enabled, forKey: key)
            model.select(model.engine.date(2026, 10, 24))
            try await Task.sleep(for: .milliseconds(150))
            let scroll = try coordinator()
            model.moveMonth(1, animated: true)
            try await wait("月份导航未启动刷新驱动") { scroll.hasActiveSnapDriver }
            try check(scroll.snapFrameRateRange, enabled: enabled)
            try await wait("月份导航未结束") { !scroll.hasActiveSnapDriver && model.calendarScrollAnimationSelection == nil }
            try require(model.selection == model.engine.date(2026, 11, 24), "刷新驱动未完成月份导航")
            let count = scroll.snapFrameTimestamps.count
            try require(count > 2, "月份导航缺少真实刷新回调")
            try await Task.sleep(for: .milliseconds(80))
            try require(scroll.snapFrameTimestamps.count == count, "导航结束后刷新回调未停止")
            reports.append(["enabled": enabled, "screenMaximumFPS": root.window?.screen?.maximumFramesPerSecond ?? 60,
                            "targetTimestamps": scroll.snapFrameTimestamps])

            model.moveMonth(1, animated: true)
            try await wait("取消场景未启动刷新驱动") { scroll.hasActiveSnapDriver }
            scroll.beginInteraction()
            let cancelledCount = scroll.snapFrameTimestamps.count
            try await Task.sleep(for: .milliseconds(80))
            try require(!scroll.hasActiveSnapDriver && scroll.snapFrameTimestamps.count == cancelledCount,
                        "新手势未停止旧刷新驱动")

            model.openYearOverview()
            try await wait("月年过渡未启动刷新驱动") { presentation.hasActiveFrameDriver }
            try check(presentation.activeFrameRateRange, enabled: enabled)
            defaults.set(!enabled, forKey: key)
            try await wait("运行中的月年过渡未更新刷新率偏好") {
                guard let range = presentation.activeFrameRateRange else { return false }
                return enabled ? range.preferred == CAFrameRateRange.default.preferred : (range.preferred ?? 0) > 0
            }
            try check(presentation.activeFrameRateRange, enabled: !enabled)
            try await wait("月年过渡未结束") { !presentation.isTransitioning && !presentation.hasActiveFrameDriver }
            model.showingYearOverview = false
            try await Task.sleep(for: .milliseconds(600))
            try await wait("返回月视图未完成") { !presentation.isTransitioning }
        }
        let scroll = try coordinator()
        model.moveMonth(1, animated: true)
        try await wait("关闭场景未启动刷新驱动") { scroll.hasActiveSnapDriver }
        close()
        try await wait("关闭弹窗后刷新驱动仍运行") { !scroll.hasActiveSnapDriver }
        let count = scroll.snapFrameTimestamps.count
        try await Task.sleep(for: .milliseconds(100))
        try require(scroll.snapFrameTimestamps.count == count, "关闭后仍收到滚动刷新回调")
        reopen()
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("refresh-rate.json"))
        try "刷新率偏好、屏幕能力请求、动态切换、月份导航、手势取消及关闭清理验证通过；时间戳不代表物理呈现帧率。\n"
            .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
