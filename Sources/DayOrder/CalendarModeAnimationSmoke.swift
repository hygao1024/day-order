#if DEBUG
import AppKit
import DayOrderCore
import Foundation

@MainActor enum CalendarModeAnimationSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController, panel: CalendarPanel,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL, reopen: () -> Void,
                       save: (NSView, String) throws -> Void) async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "DayOrder.ModeAnimation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() {
                try require(Date() < deadline, "日程缩放动画未在期限内就绪或结束：模式=\(model.events.mode)，过渡=\(presentation.isTransitioning)，读取=\(model.events.loading)，采样=\(presentation.isPreparedForSampling)，窗口=\(panel.frame)，托管=\(presentation.host.view.frame)，fitting=\(presentation.host.view.fittingSize)，natural=\(String(describing: presentation.shell?.naturalSize))")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func button() throws -> CalendarEventModeButton {
            guard let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarEventModeButton }).first else {
                throw CocoaError(.coderInvalidValue)
            }
            return button
        }
        func prepared() async throws {
            try require(presentation.isTransitioning, "切档未启动缩放动画，正文仍直接跳变")
            try await wait { presentation.isPreparedForSampling && !model.events.loading }
        }
        func draw() { presentation.transitionView?.display() }
        func finish() {
            if presentation.isPreparedForSampling {
                presentation.sampleGeometry(deltaTime: 1)
                presentation.finishGeometrySampling()
            }
        }
        func bitmap(_ view: NSView, _ rect: CGRect) throws -> NSBitmapImageRep {
            guard let image = view.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.coderInvalidValue) }
            view.cacheDisplay(in: rect, to: image)
            return image
        }
        func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> Double {
            try require(a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh, "像素比较区域尺寸不一致")
            var error = 0.0
            for y in 0..<a.pixelsHigh {
                for x in 0..<a.pixelsWide {
                    guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw CocoaError(.coderInvalidValue) }
                    let aa = ca.alphaComponent, ab = cb.alphaComponent
                    error += abs(ca.redComponent * aa - cb.redComponent * ab)
                        + abs(ca.greenComponent * aa - cb.greenComponent * ab)
                        + abs(ca.blueComponent * aa - cb.blueComponent * ab) + abs(aa - ab)
                }
            }
            return error * 255 / Double(a.pixelsWide * a.pixelsHigh * 4)
        }
        let events = model.events
        let original = model.selection
        let originalToday = model.today
        let behavior = panel.behavior
        let appearance = defaults.object(forKey: "appearance")
        guard let screen = panel.screen else { throw CocoaError(.coderInvalidValue) }
        let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX,
            y: screen.visibleFrame.maxY - 24, width: 24, height: 24),
            styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        anchorWindow.contentView = anchor
        // 屏幕坐标断言需要固定锚点，避免系统菜单栏重排带动整个面板移动。
        panel.show(anchoredTo: anchor)
        defer { anchorWindow.close() }
        panel.behavior = .applicationDefined
        presentation.reduceMotionOverride = false
        presentation.controlsAnimationClock = true
        defer {
            presentation.cancelTransition()
            presentation.controlsAnimationClock = false
            presentation.reduceMotionOverride = nil
            panel.behavior = behavior
            defaults.set(appearance, forKey: "appearance")
            events.choose(.hidden)
            model.today = originalToday
            model.select(original)
        }
        var report: [[String: Any]] = []
        for month in [2, 8, 11] {
            defaults.set(month == 8 ? "dark" : "light", forKey: "appearance")
            var local = Calendar(identifier: .gregorian)
            local.timeZone = .current
            let start = local.date(from: DateComponents(year: 2026, month: month, day: 5, hour: 10))!
            let value = CalendarEvent(id: "motion", title: "周会与项目讨论", start: start,
                end: start.addingTimeInterval(3600), allDay: false,
                color: .init(red: 0.3, green: 0.5, blue: 0.9))
            await source.configure(access: .fullAccess, values: [value])
            events.choose(.hidden)
            finish()
            model.today = model.engine.date(2026, month, 5)
            model.select(model.today)
            try await Task.sleep(for: .milliseconds(120))
            try await wait { !events.loading && !presentation.isTransitioning }
            let selection = model.selection
            let monthDate = model.month
            presentation.reduceMotionOverride = true
            var staticPixels: [[String: Any]] = []
            for mode in [CalendarEventDisplay.detailed, .compact, .dots, .hidden] {
                let area = presentation.view.convert(presentation.shell!.content.bounds, from: presentation.shell!.content)
                    .insetBy(dx: 12, dy: 1)
                let live = try bitmap(presentation.view, area)
                let control = try button()
                try require(control.sendAction(control.action, to: control.target), "日程按钮未启动静态端点检查")
                let frozenError = try difference(live, bitmap(presentation.view, area))
                try require(frozenError < 0.1, "切档冻结画面与原日期区不一致：月份=\(month)，模式=\(mode)，误差=\(frozenError)")
                try await prepared()
                presentation.sampleGeometry(deltaTime: 1)
                draw()
                let targetArea = presentation.movingCardFrame!.insetBy(dx: 12, dy: 1)
                let target = try bitmap(presentation.view, targetArea)
                try save(presentation.view, "mode-static-\(month)-\(mode.rawValue)")
                finish()
                presentation.view.layoutSubtreeIfNeeded()
                let targetError = try difference(target, bitmap(presentation.view, targetArea))
                try require(targetError < 0.1, "减少动态效果的端点交接发生像素跳变：月份=\(month)，模式=\(mode)，误差=\(targetError)")
                staticPixels.append(["mode": mode.rawValue, "frozenPixelError": frozenError, "targetPixelError": targetError])
            }
            try JSONSerialization.data(withJSONObject: staticPixels, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("mode-static-pixels-\(month).json"))
            presentation.reduceMotionOverride = false
            for mode in [CalendarEventDisplay.detailed, .compact, .dots, .hidden] {
                let top = panel.frame.maxY
                let shell = presentation.shell!
                let material = presentation.material
                let startHeight = shell.content.frame.height
                let revision = events.revision
                let headerInScreen = panel.convertToScreen(shell.header.convert(shell.header.bounds, to: nil))
                var headerPhase = "prepare"
                var headerPositions: [[String: Any]] = []
                func observeHeader(_ current: CalendarShellView) {
                    let actual = panel.convertToScreen(current.header.convert(current.header.bounds, to: nil))
                    headerPositions.append(["phase": headerPhase, "x": actual.minX, "top": actual.maxY,
                        "width": actual.width, "height": actual.height, "calendarHeight": current.calendarHeight,
                        "windowX": panel.frame.minX, "windowTop": panel.frame.maxY, "windowHeight": panel.frame.height,
                        "rootHeight": presentation.view.bounds.height,
                        "hostingHeight": presentation.host.view.frame.height,
                        "headerInRootX": presentation.view.convert(current.header.bounds, from: current.header).minX,
                        "headerInRootY": presentation.view.convert(current.header.bounds, from: current.header).minY,
                        "shellInRootY": presentation.view.convert(current.bounds, from: current).minY,
                        "xError": actual.minX - headerInScreen.minX,
                        "topError": actual.maxY - headerInScreen.maxY,
                        "error": max(abs(actual.minX - headerInScreen.minX), abs(actual.maxY - headerInScreen.maxY),
                                     abs(actual.width - headerInScreen.width), abs(actual.height - headerInScreen.height))])
                }
                shell.layoutObserver = observeHeader
                defer { shell.layoutObserver = nil }
                observeHeader(shell)
                let retargets = presentation.retargetCount
                let headerRect = CGRect(x: 12, y: 8, width: 125, height: 28)
                let footerRect = CGRect(x: 12, y: 8, width: 150, height: 44)
                let oldHeader = try bitmap(shell.header.superview!, headerRect)
                let oldFooter = try bitmap(shell.footer.superview!, footerRect)
                try button().performClick(nil)
                try require(events.mode == mode, "真实按钮没有按顺序切档")
                try await prepared()
                let preparationSamples = headerPositions.filter { $0["phase"] as? String == "prepare" &&
                    $0["calendarHeight"] as? CGFloat == mode.viewportHeight }
                try require(!preparationSamples.isEmpty, "未采集到目标行高的真实准备阶段布局")
                try JSONSerialization.data(withJSONObject: headerPositions, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("header-position-\(month)-\(mode.rawValue).json"))
                let changedHeader = headerPositions.first { ($0["error"] as! CGFloat) >= 0.01 }
                try require(changedHeader == nil,
                            "准备阶段页眉屏幕矩形发生变化：月份=\(month)，模式=\(mode)，样本=\(String(describing: changedHeader))")
                headerPhase = "animation"
                if mode == .compact || mode == .dots {
                    try require(events.revision == revision && presentation.retargetCount == retargets,
                                "相同日程结果重复发布并重启切档过渡")
                }
                var frames: [[String: Double]] = []
                for index in 0...72 {
                    presentation.sampleGeometry(deltaTime: index == 0 ? 0 : 1.0 / 120)
                    draw()
                    guard let card = presentation.movingCardFrame, let cells = presentation.eventModeSample else {
                        throw NSError(domain: "DayOrder.ModeAnimation", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "缩放缺少逐格绘制，或没有实际中间画面"])
                    }
                    try require(shell === presentation.shell && material === presentation.material,
                                "切档重建了原有外壳或材质")
                    try require(shell.content.alphaValue == 0 && shell.chromeCoverage >= 0.999,
                                "过渡时原正文闪现或上下栏消失")
                    try require(cells["elements"] == cells["rendered"] && cells["elements"]! >= 28,
                                "日期格没有完整参与连续绘制")
                    let weeks = model.calendarTimeline(firstWeekday: 1).weekRows(inMonth: model.month)!.count
                    if cells["destinationElements"] != Double(weeks * 8) {
                        try save(presentation.view, "mode-motion-layout-failure")
                        if let table = descendants(presentation.host.view).compactMap({ $0 as? NSTableView }).first,
                           let scroll = table.enclosingScrollView {
                            let rows = table.rows(in: table.visibleRect)
                            let diagnostics: [String: Any] = [
                                "visible": NSStringFromRect(table.visibleRect), "scroll": NSStringFromRect(scroll.bounds),
                                "rows": (rows.location..<NSMaxRange(rows)).map { row in
                                    ["row": row, "frame": NSStringFromRect(table.rect(ofRow: row))] as [String: Any]
                                },
                                "buttons": descendants(table).compactMap { $0 as? CalendarDayButton }.map {
                                    ["date": String(describing: $0.date), "mode": $0.eventMode.rawValue,
                                     "frame": NSStringFromRect($0.frame)]
                                }
                            ]
                            try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
                                .write(to: directory.appendingPathComponent("mode-motion-layout-failure.json"))
                        }
                    }
                    try require(cells["destinationElements"] == Double(weeks * 8),
                                "目标端点被起点窗口裁掉了日期或周分隔线：月份=\(month)，模式=\(mode)，实际=\(cells["destinationElements"]!)，预期=\(weeks * 8)")
                    try require(abs(panel.frame.maxY - top) < 1 && abs(panel.contentSize.height - presentation.preferredContentSize.height) < 1,
                                "面板未随正文缩放或顶部锚点跳动：月份=\(month)，模式=\(mode)，帧=\(index)，top=\(top)→\(panel.frame.maxY)，实际高度=\(panel.contentSize.height)，期望=\(presentation.preferredContentSize.height)")
                    try require(model.selection == selection && model.month == monthDate, "缩放改变了选择或浏览月份")
                    var sample = cells
                    sample["height"] = card.height
                    sample["progress"] = presentation.progress
                    sample["time"] = presentation.elapsedFraction
                    sample["seconds"] = presentation.motionSeconds
                    let footer = presentation.view.convert(shell.footer.bounds, from: shell.footer)
                    try require(abs(footer.minY - card.maxY) < 1, "底栏没有连续跟随卡片下沿")
                    frames.append(sample)
                    if [0, 10, 22, 72].contains(index) {
                        let headerError = try difference(oldHeader, bitmap(shell.header.superview!, headerRect))
                        let footerError = try difference(oldFooter, bitmap(shell.footer.superview!, footerRect))
                        try require(headerError < 0.1 && footerError < 0.1,
                                    "切档改变了上下栏文字亮度：页眉=\(headerError)，底栏=\(footerError)")
                        frames[frames.count - 1]["headerPixelError"] = headerError
                        frames[frames.count - 1]["footerPixelError"] = footerError
                        try save(presentation.view, "mode-motion-\(month)-\(mode.rawValue)-\(index)")
                    }
                }
                let target = mode.viewportHeight
                try JSONSerialization.data(withJSONObject: frames, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("mode-motion-\(month)-\(mode.rawValue).json"))
                try require(abs(startHeight - target) > 10, "样例没有覆盖实际高度变化")
                try require(frames.contains { abs($0["height"]! - startHeight) > 1 && abs($0["height"]! - target) > 1 },
                            "正文没有连续高度中间态")
                let early = frames.filter { $0["seconds"]! >= 0.02 && $0["seconds"]! <= 0.07 }
                try require(!early.isEmpty && early.allSatisfy { $0["progress"]! <= 2 * $0["time"]! + 0.015 }
                            && frames.contains { abs($0["progress"]! - $0["time"]!) > 0.04 },
                            "动画不是柔和起步的非线性运动")
                let startingError = frames.first!["endError"]!
                try require(startingError > 1 && frames.contains { $0["endError"]! > 1 && $0["endError"]! < startingError - 1 },
                            "日期格缺少真实移动中间态")
                try require(frames.last!["endError"]! < 0.2 && abs(frames.last!["height"]! - target) < 0.2,
                            "日期格或容器未收敛到真实终点")
                for pair in zip(frames, frames.dropFirst()) {
                    try require(abs(pair.1["height"]! - target) <= abs(pair.0["height"]! - target) + 0.05,
                                "单次切档的容器反弹或反向跳动")
                }
                let dates = try descendants(presentation.host.view).compactMap { $0 as? CalendarDayButton }
                    .filter { !$0.isHidden }.compactMap { button -> (CGRect, NSBitmapImageRep)? in
                        let rect = presentation.view.backingAlignedRect(
                            presentation.view.convert(CGRect(x: 2, y: 0, width: button.bounds.width - 4, height: 43), from: button),
                            options: .alignAllEdgesOutward)
                        guard presentation.movingCardFrame!.contains(rect) else { return nil }
                        return (rect, try bitmap(presentation.view, rect))
                    }
                headerPhase = "handoff"
                finish()
                presentation.view.layoutSubtreeIfNeeded()
                observeHeader(shell)
                var handoffError = 0.0
                for (rect, image) in dates {
                    handoffError = max(handoffError, try difference(image, bitmap(presentation.view, rect)))
                }
                try save(presentation.view, "mode-motion-\(month)-\(mode.rawValue)-live")
                try require(!dates.isEmpty && handoffError < 0.1,
                            "日期快照交还真实视图时像素跳变：\(handoffError)")
                try require(shell.content.alphaValue == 1 && !presentation.hasActiveFrameDriver && !presentation.isTransitioning,
                            "交接后没有恢复真实正文或停止刷新")
                let callbacks = presentation.driverCallbackCount
                try await Task.sleep(for: .milliseconds(20))
                try require(callbacks == presentation.driverCallbackCount, "动画结束后仍在刷新")
                try JSONSerialization.data(withJSONObject: headerPositions, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("header-position-\(month)-\(mode.rawValue).json"))
                try require(headerPositions.allSatisfy { ($0["error"] as! CGFloat) < 0.01 },
                            "动画或交接阶段顶部发生位移")
                shell.layoutObserver = nil
                report.append(["month": month, "mode": mode.rawValue, "frames": frames,
                               "headerPositions": headerPositions, "handoffPixelError": handoffError])
            }
        }
        guard let table = descendants(presentation.host.view).compactMap({ $0 as? NSTableView })
            .first(where: { $0.identifier?.rawValue == "calendarTimeline" }),
              let scroll = table.enclosingScrollView as? CalendarTimelineScrollView else { throw CocoaError(.coderInvalidValue) }
        scroll.onActivity?()
        let origin = table.visibleRect.minY + 20
        scroll.contentView.scroll(to: table.convert(NSPoint(x: 0, y: origin), to: scroll.contentView))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(60))
        let viewport = model.calendarViewport!
        let selection = model.selection
        try button().performClick(nil)
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.08)
        draw()
        try save(presentation.view, "mode-motion-free-middle")
        finish()
        let row = model.calendarTimeline(firstWeekday: 1).weekRow(containing: viewport.date, inMonth: viewport.month)
        try require(model.selection == selection && model.calendarSnappedMonth == nil &&
                    abs(table.visibleRect.minY - table.rect(ofRow: row).minY - viewport.offset) < 1,
                    "自由滚动位置在切档后跳回了月初或选中日期")
        events.choose(.hidden)
        try await prepared()
        finish()
        model.goToToday()
        try await Task.sleep(for: .milliseconds(80))
        // 连续点击保留正在显示的格子与速度，不退回上一个端点。
        let rapidShell = presentation.shell!
        let rapidHeader = panel.convertToScreen(rapidShell.header.convert(rapidShell.header.bounds, to: nil))
        var rapidErrors: [CGFloat] = []
        rapidShell.layoutObserver = { current in
            let actual = panel.convertToScreen(current.header.convert(current.header.bounds, to: nil))
            rapidErrors.append(max(abs(actual.maxY - rapidHeader.maxY), abs(actual.minX - rapidHeader.minX),
                                   abs(actual.height - rapidHeader.height), abs(actual.width - rapidHeader.width)))
        }
        defer { rapidShell.layoutObserver = nil }
        try button().performClick(nil)
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.06)
        draw()
        var retargetPixels: [[String: Any]] = []
        for mode in [CalendarEventDisplay.compact, .dots, .hidden, .detailed] {
            let area = presentation.view.backingAlignedRect(presentation.movingCardFrame!, options: .alignAllEdgesOutward)
            let before = try bitmap(presentation.view, area)
            let retargets = presentation.retargetCount
            try button().performClick(nil)
            try await prepared()
            presentation.sampleGeometry(deltaTime: 0)
            draw()
            try require(events.mode == mode && presentation.eventModeSample != nil && presentation.retargetCount > retargets &&
                        presentation.retargetPositionError < 0.001 && presentation.retargetVelocityError < 0.001,
                        "连续切档清零了日期格的位置或速度")
            let pixelError = try difference(before, bitmap(presentation.view, area))
            try require(pixelError < 0.1, "连续切档的底图重新采样造成像素跳变：\(pixelError)")
            retargetPixels.append(["mode": mode.rawValue, "error": pixelError])
            presentation.sampleGeometry(deltaTime: 0.04)
            draw()
        }
        try JSONSerialization.data(withJSONObject: retargetPixels, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("mode-retarget-pixels.json"))
        rapidShell.layoutObserver = nil
        try require(!rapidErrors.isEmpty && rapidErrors.allSatisfy { $0 < 0.01 }, "快速切档移动了顶部")
        try JSONSerialization.data(withJSONObject: rapidErrors, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("header-position-rapid.json"))
        // 设置共享同一展示驱动，中途进入设置不能先交还一帧真实正文。
        model.showingSettings = true
        try await prepared()
        try require(presentation.retargetPositionError < 0.001 && presentation.retargetVelocityError < 0.001,
                    "进入设置没有承接缩放中的容器运动")
        finish()
        model.showingSettings = false
        try await prepared()
        finish()
        model.openYearOverview()
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.06)
        model.dismissYearLevel()
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.04)
        try button().performClick(nil)
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.6)
        draw()
        try require(presentation.canvasSample == nil &&
                    abs(presentation.movingCardFrame!.height - events.mode.viewportHeight) < 0.2,
                    "月年返回途中切档仍使用旧模式画布，交接会发生跳变")
        finish()
        presentation.reduceMotionOverride = true
        events.choose(.hidden)
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0)
        let reduced = presentation.movingCardFrame
        presentation.sampleGeometry(deltaTime: 0.06)
        try require(presentation.movingCardFrame == reduced && presentation.eventModeSample == nil,
                    "减少动态效果仍保留位移缩放")
        finish()
        presentation.reduceMotionOverride = false
        // 真实显示刷新回调也要收敛，不能只靠受控时钟。
        presentation.controlsAnimationClock = false
        let callbacks = presentation.driverCallbackCount
        let liveShell = presentation.shell!
        let liveHeader = panel.convertToScreen(liveShell.header.convert(liveShell.header.bounds, to: nil))
        var liveErrors: [CGFloat] = []
        liveShell.layoutObserver = { current in
            let actual = panel.convertToScreen(current.header.convert(current.header.bounds, to: nil))
            liveErrors.append(max(abs(actual.maxY - liveHeader.maxY), abs(actual.minX - liveHeader.minX),
                                  abs(actual.height - liveHeader.height), abs(actual.width - liveHeader.width)))
        }
        defer { liveShell.layoutObserver = nil }
        try button().performClick(nil)
        try await wait { !presentation.isTransitioning }
        liveShell.layoutObserver = nil
        try require(!liveErrors.isEmpty && liveErrors.allSatisfy { $0 < 0.01 }, "真实刷新回调期间顶部发生位移")
        try JSONSerialization.data(withJSONObject: liveErrors, options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("header-position-live.json"))
        try require(presentation.driverCallbackCount > callbacks && !presentation.hasActiveFrameDriver,
                    "真实显示驱动没有完成并清理缩放")
        presentation.controlsAnimationClock = true
        try button().performClick(nil)
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.05)
        model.goToToday()
        try require(!presentation.isTransitioning && !presentation.hasActiveFrameDriver,
                    "导航没有取消旧的日程缩放")
        try button().performClick(nil)
        try await prepared()
        presentation.sampleGeometry(deltaTime: 0.05)
        panel.close()
        try require(!presentation.isTransitioning && !presentation.hasActiveFrameDriver && presentation.shell?.content.alphaValue == 1,
                    "关闭没有清理缩放或恢复正文")
        reopen()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("mode-motion.json"))
    }
}
#endif
