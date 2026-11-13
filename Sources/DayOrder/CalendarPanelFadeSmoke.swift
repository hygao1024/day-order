#if DEBUG
import AppKit
import DayOrderCore
import QuartzCore

@MainActor enum CalendarPanelFadeSmoke {
    static func verify(panel: CalendarPanel, anchor: NSView, model: CalendarModel, defaults: UserDefaults,
                       directory: URL, toggle: () -> Void) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DayOrder.PanelFade", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let behavior = panel.behavior
        let appearance = defaults.object(forKey: "appearance")
        let onShow = panel.onShow
        let onClose = panel.onClose
        // 先满足与实际点击菜单栏图标相同的锚点前置条件。
        let anchorDeadline = Date().addingTimeInterval(2)
        while anchor.window?.screen == nil {
            try require(Date() < anchorDeadline, "菜单栏锚点未连接到屏幕")
            try await Task.sleep(for: .milliseconds(5))
        }
        panel.closeImmediately()
        var shows = 0
        var closes = 0
        panel.onShow = { shows += 1; onShow?() }
        panel.onClose = { closes += 1; onClose?() }
        panel.behavior = .applicationDefined
        panel.controlsFadeClock = true
        panel.fadeReduceMotionOverride = false
        defer {
            panel.closeImmediately()
            panel.controlsFadeClock = false
            panel.fadeReduceMotionOverride = nil
            panel.onShow = onShow
            panel.onClose = onClose
            panel.behavior = behavior
            defaults.set(appearance, forKey: "appearance")
            panel.show(anchoredTo: anchor)
        }
        var report: [[String: Any]] = []
        func capture(_ name: String) async throws {
            panel.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(20))
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber))
                as? [[String: Any]]
            guard let serverAlpha = info?.first?[kCGWindowAlpha as String] as? Double,
                  let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                    CGWindowID(panel.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                throw NSError(domain: "DayOrder.PanelFade", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取面板的窗口服务器透明度或图像"])
            }
            try require(abs(serverAlpha - panel.alphaValue) < 0.02, "窗口服务器透明度与动画状态不一致")
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: directory.appendingPathComponent(name + ".png"))
            report.append(["sample": name, "alpha": panel.alphaValue, "serverAlpha": serverAlpha,
                "screenScale": panel.backingScaleFactor])
        }
        func waitForFade() async throws {
            let deadline = Date().addingTimeInterval(2)
            while panel.isFading {
                try require(Date() < deadline, "面板透明度动画未及时完成")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        for style in ["light", "dark"] {
            defaults.set(style, forKey: "appearance")
            toggle()
            try await Task.sleep(for: .milliseconds(100))
            let frame = panel.frame
            try require(panel.isShown && panel.isVisible && panel.alphaValue == 0 && panel.isFading,
                "面板打开缺少从透明开始的淡入：shown=\(panel.isShown)，visible=\(panel.isVisible)，alpha=\(panel.alphaValue)，fading=\(panel.isFading)，\(style)，trace=\(panel.visibilityTrace)")
            var previous: CGFloat = 0
            for time in [0.0, 0.035, 0.07, 0.135, 0.15] {
                panel.sampleFade(elapsed: time)
                try require(panel.frame == frame && panel.alphaValue >= previous,
                    "淡入改变了窗口几何或透明度发生反向跳动")
                if time == 0.035 { try require(panel.alphaValue > 0.25 && panel.alphaValue < 0.9, "淡入缺少缓出中间态") }
                if time == 0.07 { try await capture("panel-fade-\(style)-opening") }
                report.append(["appearance": style, "direction": "opening", "elapsed": time, "alpha": panel.alphaValue])
                previous = panel.alphaValue
            }
            try require(panel.alphaValue == 1 && !panel.isFading && !panel.hasFadeDriver, "淡入没有停在完全可见状态")
            let closesBefore = closes
            toggle()
            try require(!panel.isShown && panel.isVisible && panel.ignoresMouseEvents && closes == closesBefore,
                "淡出期间未隔离输入，或提前清理了页面")
            previous = 1
            for time in [0.02, 0.045, 0.085, 0.1] {
                panel.sampleFade(elapsed: time)
                try require(panel.frame == frame && panel.alphaValue <= previous, "淡出改变了窗口几何或透明度反向跳动")
                if time == 0.045 { try await capture("panel-fade-\(style)-closing") }
                report.append(["appearance": style, "direction": "closing", "elapsed": time, "alpha": panel.alphaValue])
                previous = panel.alphaValue
            }
            try require(!panel.isVisible && !panel.isFading && !panel.hasFadeDriver
                && !panel.hasDismissalMonitors && closes == closesBefore + 1, "淡出结束未隐藏或未完成一次性清理")
            panel.close()
            panel.closeImmediately()
            try require(closes == closesBefore + 1, "重复关闭重复通知页面清理")
        }

        toggle()
        panel.sampleFade(elapsed: 0.035)
        model.selectVisibleDay(model.engine.addingDays(1, to: model.selection))
        try await Task.sleep(for: .milliseconds(100))
        let selection = model.selection
        let shownCount = shows
        let closedCount = closes
        for index in 0..<4 {
            let openingAlpha = panel.alphaValue
            let frame = panel.frame
            toggle()
            try require(panel.alphaValue == openingAlpha, "淡入转淡出时透明度跳变")
            panel.sampleFade(elapsed: 0.01)
            let closingAlpha = panel.alphaValue
            try require(closingAlpha > 0 && closingAlpha < openingAlpha, "快速关闭缺少淡出中间态")
            toggle()
            try require(panel.alphaValue == closingAlpha && panel.frame == frame && model.selection == selection,
                "淡出反向打开时重置透明度、页面或窗口位置")
            panel.sampleFade(elapsed: 0.02)
            try require(panel.alphaValue > closingAlpha && shows == shownCount && closes == closedCount,
                "快速反向没有继续淡入或重复触发生命周期回调")
            report.append(["scenario": "reverse", "index": index, "from": openingAlpha,
                "reversedAt": closingAlpha, "resumed": panel.alphaValue])
        }
        panel.sampleFade(elapsed: 1)
        toggle()
        panel.sampleFade(elapsed: 1)
        toggle()
        try require(model.selection == model.engine.clamped(model.today), "完全关闭后重新打开没有回到今天")
        panel.sampleFade(elapsed: 1)
        toggle()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try require(!panel.isVisible && !panel.isFading && !panel.hasDismissalMonitors,
            "淡出期间屏幕变化没有立即关闭并清理")
        toggle()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try require(!panel.isVisible && !panel.isFading, "桌面切换没有取消淡入")

        panel.fadeReduceMotionOverride = true
        toggle()
        try require(panel.alphaValue == 1 && !panel.isFading, "减少动态效果仍执行淡入")
        toggle()
        try require(!panel.isVisible && !panel.isFading, "减少动态效果仍执行淡出")
        panel.fadeReduceMotionOverride = false
        toggle()
        panel.sampleFade(elapsed: 0.03)
        panel.fadeReduceMotionOverride = true
        panel.sampleFade(elapsed: 0.04)
        try require(panel.alphaValue == 1 && !panel.isFading, "动态开启减少动态效果未结束过渡")
        panel.closeImmediately()

        panel.controlsFadeClock = false
        panel.fadeReduceMotionOverride = false
        let startFrames = panel.fadeFrameCount
        toggle()
        var alphas: [CGFloat] = []
        let deadline = Date().addingTimeInterval(2)
        while panel.isFading {
            try require(Date() < deadline, "真实淡入刷新驱动未完成")
            alphas.append(panel.alphaValue)
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(panel.fadeFrameCount > startFrames && alphas.contains { $0 > 0.05 && $0 < 0.95 }
            && panel.alphaValue == 1 && !panel.hasFadeDriver, "真实刷新驱动没有绘制淡入中间态或未停止")
        report.append(["scenario": "live-opening", "alphas": alphas, "frames": panel.fadeFrameCount - startFrames])
        toggle()
        try await waitForFade()
        try require(!panel.isVisible && !panel.hasFadeDriver && !panel.hasDismissalMonitors, "真实淡出未完成清理")
        let stoppedFrames = panel.fadeFrameCount
        try await Task.sleep(for: .milliseconds(80))
        try require(panel.fadeFrameCount == stoppedFrames, "隐藏后仍收到透明度刷新回调")
        toggle()
        try await Task.sleep(for: .milliseconds(20))
        panel.closeImmediately()
        let cancelledFrames = panel.fadeFrameCount
        try await Task.sleep(for: .milliseconds(80))
        try require(!panel.hasFadeDriver && panel.fadeFrameCount == cancelledFrames, "立即关闭没有停止淡入刷新驱动")
        report.append(["scenario": "visibility-lifecycle", "trace": panel.visibilityTrace])
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("panel-fade.json"))
    }
}
#endif
