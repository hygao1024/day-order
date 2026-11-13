#if DEBUG
import AppKit
import DayOrderCore
import QuartzCore

@MainActor enum CalendarAgendaAnimationSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL,
                       save: (NSView, String) throws -> Void) async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "DayOrder.AgendaAnimation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func contentBottom(_ button: CalendarDayButton) -> CGFloat {
            button.superview!.subviews.compactMap { $0 as? CalendarDayButton }.map { day in
                let bottom = max(day.focusRingMaskBounds.maxY,
                                 day.eventMarkers.map { $0.style.frame.maxY }.max() ?? 0)
                return presentation.view.convert(NSPoint(x: 0, y: bottom), from: day).y
            }.max()!
        }
        func pixel(_ view: NSView, at point: NSPoint) throws -> [CGFloat] {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "DayOrder.AgendaAnimation", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "背景采样无法创建位图：\(type(of: view))，\(view.bounds)"])
            }
            // 透明视图不覆盖展开外的像素，采样缓冲区不能保留此前分配的内容。
            bitmap.bitmapData?.update(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let x = Int((point.x - view.bounds.minX) * CGFloat(bitmap.pixelsWide) / view.bounds.width)
            let y = Int((point.y - view.bounds.minY) * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                throw NSError(domain: "DayOrder.AgendaAnimation", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "背景采样像素不可读：\(type(of: view))，坐标=\(x),\(y)，位图=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"])
            }
            let alpha = color.alphaComponent
            return [color.redComponent * alpha, color.greenComponent * alpha, color.blueComponent * alpha, alpha]
        }
        func rowWidth(_ view: NSView, rect: CGRect, y: CGFloat) throws -> CGFloat {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CocoaError(.coderInvalidValue)
            }
            bitmap.bitmapData?.update(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let row = Int((y - view.bounds.minY) * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            let first = max(0, Int((rect.minX - view.bounds.minX) * scale))
            let last = min(bitmap.pixelsWide - 1, Int((rect.maxX - view.bounds.minX) * scale))
            let occupied = (first...last).filter { (bitmap.colorAt(x: $0, y: row)?.alphaComponent ?? 0) > 0.025 }
            guard let left = occupied.first, let right = occupied.last else {
                throw NSError(domain: "DayOrder.AgendaAnimation", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "日程展开轮廓采样没有可见内容"])
            }
            return CGFloat(right - left + 1) / scale
        }
        func windowImage(_ name: String) async throws -> NSBitmapImageRep {
            guard let window = presentation.view.window else { throw CocoaError(.coderInvalidValue) }
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(80))
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                throw NSError(domain: "DayOrder.AgendaAnimation", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "无法采集窗口服务器图像，请检查屏幕录制权限与图形会话"])
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            return bitmap
        }
        func windowPixel(_ bitmap: NSBitmapImageRep, at point: NSPoint) throws -> [CGFloat] {
            let bounds = presentation.view.bounds
            let x = Int(point.x * CGFloat(bitmap.pixelsWide) / bounds.width)
            let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / bounds.height)
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                throw CocoaError(.coderInvalidValue)
            }
            return [color.redComponent, color.greenComponent, color.blueComponent]
        }
        func ready() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.events.loading || (presentation.isTransitioning && !presentation.isPreparedForSampling) {
                try require(Date() < deadline, "日程展开动画未及时就绪")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func finish() async throws {
            try await ready()
            if presentation.isPreparedForSampling {
                presentation.sampleGeometry(deltaTime: 1)
                presentation.finishGeometrySampling()
            }
            presentation.view.layoutSubtreeIfNeeded()
        }
        func visibleButton(for date: Date) async throws -> CalendarDayButton {
            let deadline = Date().addingTimeInterval(3)
            while true {
                presentation.host.view.layoutSubtreeIfNeeded()
                if let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayButton })
                    .first(where: { $0.date == date && !$0.visibleRect.isEmpty }) { return button }
                try require(Date() < deadline, "日程动画样例日期未进入可视区：\(date)")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let original = model.selection
        let weekday = defaults.object(forKey: "firstWeekday")
        let appearance = defaults.object(forKey: "appearance")
        presentation.controlsAnimationClock = true
        presentation.reduceMotionOverride = false
        defaults.set(1, forKey: "firstWeekday")
        defer {
            presentation.cancelTransition()
            presentation.controlsAnimationClock = false
            presentation.reduceMotionOverride = nil
            model.closeAgenda()
            model.events.choose(.hidden)
            model.select(original)
            defaults.set(weekday, forKey: "firstWeekday")
            defaults.set(appearance, forKey: "appearance")
        }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let events = [1, 7].map { day in
            let start = local.date(from: DateComponents(year: 2026, month: 11, day: day))!
            return CalendarEvent(id: "animation-\(day)", title: day == 1 ? "万圣节" : "立冬",
                start: start, end: start.addingTimeInterval(86400), allDay: true,
                color: .init(red: 0.95, green: 0.5, blue: 0.05), calendarTitle: "日程动画预览")
        }
        await source.configure(access: .fullAccess, values: events)
        model.events.choose(.detailed)
        var report: [[String: Any]] = []
        let capturesWindow = ProcessInfo.processInfo.arguments.contains("--capture-agenda-window")
        var captureAnchorWindow: NSWindow?
        let lowRefresh = ProcessInfo.processInfo.arguments.contains("--agenda-low-refresh-screen")
        let testScreen = lowRefresh
            ? NSScreen.screens.min(by: { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond })
            : NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor })
        // 离屏轮廓检查也使用真实锚定入口，避免隐藏面板以默认倍率采样。
        if let panel = presentation.view.window as? CalendarPanel,
           let screen = testScreen {
            let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 24,
                width: 24, height: 24), styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            anchorWindow.setFrame(NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 24,
                width: 24, height: 24), display: false)
            anchorWindow.isReleasedWhenClosed = false
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
            anchorWindow.contentView = anchor
            captureAnchorWindow = anchorWindow
            panel.show(anchoredTo: anchor)
        }
        defer { captureAnchorWindow?.close() }
        let pixelTolerance = 1 / (presentation.view.window?.backingScaleFactor ?? 2) + 0.001
        report.append(["screenScale": presentation.view.window?.backingScaleFactor ?? 0,
            "screenMaximumFPS": presentation.view.window?.screen?.maximumFramesPerSecond ?? 0])
        for style in ["light", "dark"] {
            defaults.set(style, forKey: "appearance")
            for number in [1, 7] {
                model.closeAgenda()
                let date = model.engine.date(2026, 11, number)
                model.select(date)
                try await finish()
                try await Task.sleep(for: .milliseconds(100))
                try await finish()
                let button = try await visibleButton(for: date)
                let expectedOriginY = contentBottom(button) + 8
                let window = presentation.view.window!.frame
                var nativeColor: [CGFloat] = []
                var agendaFrame = NSRect.zero
                var screenProbes: [(Int, [CGFloat])] = []
                for direction in ["opening", "closing"] {
                    try require(button.accessibilityPerformPress(), "日期未触发日程展开过渡")
                    try await ready()
                    try require(presentation.isPreparedForSampling, "日程展开过渡未启动")
                    if direction == "opening" {
                        guard let agenda = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayAgendaView })
                            .first(where: { !$0.isHidden && $0.date == date }) else {
                            throw NSError(domain: "DayOrder.AgendaAnimation", code: 3, userInfo: [NSLocalizedDescriptionKey:
                                "背景采样找不到展开后的原生日程：\(date)"])
                        }
                        if !capturesWindow {
                            nativeColor = try pixel(agenda, at: NSPoint(x: agenda.bounds.width * 0.85,
                                                                       y: agenda.bounds.height * 0.7))
                        }
                        agendaFrame = presentation.view.convert(agenda.bounds, from: agenda)
                    }
                    var previous: Double = direction == "opening" ? 0 : 1
                    var earlyHeight: Double?
                    var previousHeight: Double = direction == "opening" ? 0 : agendaFrame.height - CalendarDayAgendaLayout.backgroundTopInset - CalendarDayAgendaLayout.backgroundBottomInset
                    let snapshots = CalendarAgendaReveal.snapshotBuildCount
                    for frame in 0...48 {
                        presentation.sampleGeometry(deltaTime: frame == 0 ? 0 : 1.0 / 120)
                        presentation.transitionView?.display()
                        guard let sample = presentation.eventModeCells.values.first(where: { $0["reveal"] != nil }) else {
                            throw NSError(domain: "DayOrder.AgendaAnimation", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "日程仍使用普通下拉，缺少向下展开几何"])
                        }
                        let progress = sample["reveal"]!
                        try require(CalendarAgendaReveal.snapshotBuildCount == snapshots, "日程动画逐帧重建了内容快照")
                        let width = sample["visibleWidth"]!
                        let height = sample["visibleHeight"]!
                        try require(abs(sample["topY"]! - expectedOriginY) <= pixelTolerance,
                            "日程顶部锚点漂移")
                        try require(abs(width - (agendaFrame.width - 1)) <= pixelTolerance,
                            "日程未始终保持详情完整宽度")
                        if direction == "opening", frame == 0 {
                            try require(height == 0, "日程仍保留横线起步高度")
                        }
                        if direction == "opening", frame > 0 {
                            try require(height >= previousHeight, "日程展开高度发生回退")
                            if progress < 0.95 {
                                try require(height - previousHeight > 0.05,
                                    "日程向下展开存在等待或静止帧")
                            }
                            if frame == 2 { earlyHeight = height }
                            if frame == 4, let earlyHeight {
                                try require(height > earlyHeight * 2,
                                    "日程缺少柔和起步的非线性展开")
                            }
                        }
                        previousHeight = height
                        try require(direction == "opening" ? progress >= previous : progress <= previous,
                                    "展开或收起发生反向跳动")
                        try require(presentation.view.window!.frame == window, "展开动画改变了窗口边界")
                        let nextDivider = presentation.eventModeCells.filter { $0.key >= 0 && $0.key % 8 == 7 }
                            .compactMap { $0.value["y"] }.filter { $0 > expectedOriginY }.min()
                        if let nextDivider {
                            try require(sample["bottomY"]! <= nextDivider + pixelTolerance,
                                "展开底边覆盖了下方周分隔线")
                        }
                        previous = progress
                        if frame % 2 == 0 {
                            if !capturesWindow { try save(presentation.view, "agenda-animation-\(style)-\(number)-\(direction)-\(frame)") }
                            report.append(["appearance": style, "day": number, "direction": direction,
                                           "frame": frame, "geometry": sample])
                        }
                        if frame == 8 { try require(progress > 0.05 && progress < 0.95, "展开缺少可见中间态") }
                        if !capturesWindow, direction == "opening", [2, 4, 12].contains(frame),
                           let overlay = presentation.transitionView {
                            let actualWidth = try rowWidth(overlay, rect: agendaFrame,
                                y: sample["topY"]! + height / 2)
                            try require(abs(actualWidth - width) <= 2 * pixelTolerance,
                                "日程实际轮廓宽度不符：帧=\(frame)，像素=\(actualWidth)，预期=\(width)")
                            let below = try pixel(overlay, at: NSPoint(x: agendaFrame.midX,
                                y: sample["bottomY"]! + 2))
                            try require(below[3] < 0.01, "展开边缘下方提前出现内容")
                            report.append(["appearance": style, "day": number, "direction": direction,
                                "frame": frame, "pixelWidth": actualWidth])
                        }
                        if [8, 24, 48].contains(frame), height > 8, let overlay = presentation.transitionView {
                            guard let probeX = sample["probeX"], let probeY = sample["probeY"] else {
                                throw NSError(domain: "DayOrder.AgendaAnimation", code: 5,
                                    userInfo: [NSLocalizedDescriptionKey: "日程未使用向下展开绘制"])
                            }
                            let probe = NSPoint(x: probeX, y: probeY)
                            if !capturesWindow {
                                let color = try pixel(overlay, at: probe)
                                let error = zip(color, nativeColor).map { abs($0 - $1) }.max()!
                                try require(error <= 2 / 255,
                                    "动画背景与原生日程颜色或透明度不一致：\(style)/\(number)/\(direction)/\(frame)，动画=\(color)，原生=\(nativeColor)")
                                report.append(["appearance": style, "day": number, "direction": direction,
                                    "frame": frame, "backgroundError": error, "nativeRGBA": nativeColor, "animatedRGBA": color])
                            }
                            if capturesWindow, direction == "opening", frame == 8 || frame == 48 {
                                let bitmap = try await windowImage("agenda-window-\(style)-\(number)-\(frame)")
                                screenProbes.append((frame, try windowPixel(bitmap, at: probe)))
                            }
                        }
                    }
                    try await finish()
                    if capturesWindow, direction == "opening" {
                        try require(screenProbes.map { $0.0 } == [8, 48], "真实窗口遗漏中间帧或终点背景采样")
                        let bitmap = try await windowImage("agenda-window-\(style)-\(number)-native")
                        let native = try windowPixel(bitmap, at: NSPoint(x: agendaFrame.minX + agendaFrame.width * 0.85,
                            y: agendaFrame.minY + agendaFrame.height * 0.7))
                        for (frame, animated) in screenProbes {
                            let error = zip(animated, native).map { abs($0 - $1) }.max()!
                            report.append(["appearance": style, "day": number, "frame": frame,
                                "windowNativeRGB": native, "windowAnimatedRGB": animated, "windowColorError": error])
                            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                                .write(to: directory.appendingPathComponent("agenda-animation.json"))
                            try require(error <= 3 / 255,
                                "真实窗口动画底色与原生详情不一致：\(style)/\(number)/\(frame)，动画=\(animated)，原生=\(native)")
                        }
                    }
                    let timings = presentation.drawingMilliseconds.sorted()
                    if !timings.isEmpty {
                        report.append(["appearance": style, "day": number, "direction": direction,
                                       "drawingMedianMS": timings[timings.count / 2],
                                       "drawingP95MS": timings[min(timings.count - 1, timings.count * 95 / 100)],
                                       "drawingMaxMS": timings.last!, "snapshots": snapshots])
                    }
                }
                // 活动动画反向保留已经绘出的形状，不能从全开或全关重新开始。
                try require(button.accessibilityPerformPress(), "无法启动反向检查")
                try await ready()
                try require(presentation.isPreparedForSampling, "反向检查的展开过渡未就绪：\(style)/\(number)")
                presentation.sampleGeometry(deltaTime: 0.07)
                presentation.transitionView?.display()
                let before = presentation.eventModeCells.values.compactMap { $0["reveal"] }.first!
                model.closeAgenda()
                try await ready()
                try require(presentation.isPreparedForSampling, "反向检查的收起过渡被取消：\(style)/\(number)")
                presentation.sampleGeometry(deltaTime: 0)
                presentation.transitionView?.display()
                let after = presentation.eventModeCells.values.compactMap { $0["reveal"] }.first!
                try require(abs(before - after) < 0.0001, "途中收起重置了展开形状")
                try await finish()
                presentation.reduceMotionOverride = true
                try require(button.accessibilityPerformPress(), "无法启动减少动态效果检查")
                try await ready()
                try require(presentation.isPreparedForSampling, "减少动态效果过渡未就绪：\(style)/\(number)")
                presentation.sampleGeometry(deltaTime: 0.04)
                presentation.transitionView?.display()
                try require(presentation.eventModeSample == nil, "减少动态效果仍执行展开")
                try await finish()
                model.closeAgenda()
                try await finish()
                presentation.reduceMotionOverride = false
            }
        }
        let stacked = (0..<3).map { index in
            CalendarEvent(id: "origin-\(index)", title: "日程标记 \(index)", start: events[0].start,
                end: events[0].end, allDay: true, color: events[0].color, calendarTitle: "日程动画预览")
        }
        for mode in [CalendarEventDisplay.detailed, .compact, .dots] {
            for (scenario, values) in [("empty", [CalendarEvent]()), ("other-day", [events[1]]), ("markers", stacked)] {
                model.closeAgenda()
                try await finish()
                await source.configure(access: .fullAccess, values: values)
                model.events.choose(mode)
                model.select(model.engine.date(2026, 11, 1))
                model.events.update(month: model.month, engine: model.engine)
                try await finish()
                guard let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayButton })
                    .first(where: { $0.date == model.selection && !$0.visibleRect.isEmpty }) else {
                    throw CocoaError(.coderInvalidValue)
                }
                try require(button.eventMarkers.isEmpty == (scenario != "markers"), "起点场景标记数量不符")
                let expectedY = contentBottom(button) + 8
                for direction in ["opening", "closing"] {
                    try require(button.accessibilityPerformPress(), "起点场景未触发动画")
                    try await ready()
                    presentation.sampleGeometry(deltaTime: 0.06)
                    presentation.transitionView?.display()
                    guard let sample = presentation.eventModeCells.values.first(where: { $0["reveal"] != nil }) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    try require(abs(sample["topY"]! - expectedY) <= pixelTolerance
                        && abs(sample["visibleWidth"]! - sample["targetWidth"]!) <= pixelTolerance,
                        "动画未保持灰底顶部 8 pt 间距或详情完整宽度：\(mode)/\(scenario)/\(direction)")
                    try save(presentation.view, "agenda-animation-origin-\(mode)-\(scenario)-\(direction)")
                    report.append(["mode": "\(mode)", "scenario": scenario, "direction": direction,
                                   "expectedOriginY": expectedY, "geometry": sample])
                    try await finish()
                }
            }
        }
        let crossEvents = [8, 15, 22].map { day in
            let start = model.engine.date(2026, 11, day)
            return CalendarEvent(id: "cross-week-\(day)", title: "跨周日程 \(day)", start: start,
                end: start.addingTimeInterval(86400), allDay: true,
                color: events[0].color, calendarTitle: "日程动画预览")
        }
        model.closeAgenda()
        try await finish()
        await source.configure(access: .fullAccess, values: crossEvents)
        model.events.choose(.detailed)
        let timeline = model.calendarTimeline(firstWeekday: 1)
        let month = model.engine.date(2026, 11, 1)
        var crossReport: [[String: Any]] = []
        func writeCrossReport() throws {
            try JSONSerialization.data(withJSONObject: crossReport, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("agenda-cross-week.json"))
        }
        for style in ["light", "dark"] {
            defaults.set(style, forKey: "appearance")
            for sequence in [[15, 8], [8, 15], [22, 8], [15, 8, 15, 8]] {
                model.closeAgenda()
                model.select(model.engine.date(2026, 11, sequence[0]))
                model.events.update(month: model.month, engine: model.engine)
                try await finish()
                let initial = try await visibleButton(for: model.selection)
                try require(initial.accessibilityPerformPress(), "跨周检查无法展开初始日程")
                try await finish()
                var offsets: [Int: CGFloat] = [:]
                func captureOffset(_ day: Int) throws {
                    let date = model.engine.date(2026, 11, day)
                    guard let agenda = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayAgendaView })
                            .first(where: { !$0.isHidden && $0.date == date }),
                          let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayButton })
                            .first(where: { $0.date == date && !$0.visibleRect.isEmpty }) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    let row = timeline.weekRow(containing: date, inMonth: month)
                    offsets[-(row + 1)] = presentation.view.convert(agenda.bounds, from: agenda).minY
                        + CalendarDayAgendaLayout.backgroundTopInset
                        - presentation.view.convert(button.bounds, from: button).minY
                }
                try captureOffset(sequence[0])
                let label = "\(style)-" + sequence.map(String.init).joined(separator: "-")
                for (step, day) in sequence.dropFirst().enumerated() {
                    let button = try await visibleButton(for: model.engine.date(2026, 11, day))
                    let before = presentation.eventModeCells
                    try require(button.accessibilityPerformPress(), "跨周检查无法切换日期")
                    try await ready()
                    try require(presentation.isPreparedForSampling, "跨周过渡未就绪")
                    try captureOffset(day)
                    let frames = step == sequence.count - 2 ? 48 : 8
                    for frame in 0...frames {
                        presentation.sampleGeometry(deltaTime: frame == 0 ? 0 : 1.0 / 120)
                        presentation.transitionView?.display()
                        let cells = presentation.eventModeCells
                        for (id, gap) in offsets {
                            guard let agenda = cells[id], let reveal = agenda["reveal"], reveal > 0.0001,
                                  let owner = cells[(-id - 1) * 8] else { continue }
                            let error = abs(agenda["topY"]! - owner["y"]! - gap)
                            crossReport.append(["sequence": label, "step": step, "frame": frame,
                                "agendaID": id, "reveal": reveal, "topY": agenda["topY"]!,
                                "ownerY": owner["y"]!, "expectedGap": gap, "anchorError": error])
                            if error > pixelTolerance {
                                try writeCrossReport()
                                if capturesWindow { _ = try await windowImage("agenda-cross-week-\(label)-failure") }
                                else { try save(presentation.view, "agenda-cross-week-\(label)-failure") }
                            }
                            try require(error <= pixelTolerance,
                                "跨周日程未跟随所属周移动：\(label)/\(step)/\(frame)，误差=\(error) pt")
                            if let divider = cells[(-id - 1) * 8 + 7]?["y"] {
                                try require(agenda["bottomY"]! <= divider + pixelTolerance,
                                    "跨周日程越过所属周分隔线")
                            }
                            if frame == 0, step > 0, let old = before[id] {
                                try require(abs(agenda["topY"]! - old["topY"]!) < 0.001
                                    && abs(reveal - old["reveal"]!) < 0.001,
                                    "快速跨周切换重置了旧日程的位置或展开进度")
                            }
                        }
                        if [8, 24, 48].contains(frame) {
                            let name = "agenda-cross-week-\(label)-\(step)-\(frame)"
                            if capturesWindow { _ = try await windowImage(name) }
                            else { try save(presentation.view, name) }
                        }
                    }
                }
                try await finish()
                try require(presentation.transitionView == nil && !presentation.hasActiveFrameDriver,
                    "跨周动画交接后仍保留绘制层或刷新驱动")
                let visibleAgendas = descendants(presentation.host.view).compactMap { $0 as? CalendarDayAgendaView }
                    .filter { !$0.isHidden && !$0.visibleRect.isEmpty }
                try require(visibleAgendas.count == 1
                    && visibleAgendas[0].date == model.engine.date(2026, 11, sequence.last!),
                    "跨周交接后仍显示旧日程")
                if capturesWindow { _ = try await windowImage("agenda-cross-week-\(label)-native") }
                else { try save(presentation.view, "agenda-cross-week-\(label)-native") }
            }
        }
        try writeCrossReport()
        // 真正的刷新回调覆盖长列表和日期切换；受控截图不能代替帧驱动的完成与清理。
        model.closeAgenda()
        try await finish()
        var many = [events[1]] + crossEvents
        for index in 0..<12 {
            let start = events[0].start.addingTimeInterval(Double(index) * 1800)
            many.append(CalendarEvent(id: "animation-long-\(index)", title: "项目讨论 \(index + 1)", start: start,
                end: start.addingTimeInterval(1200), allDay: false,
                color: .init(red: 0.95, green: 0.5, blue: 0.05), calendarTitle: "日程动画预览"))
        }
        await source.configure(access: .fullAccess, values: many)
        model.events.choose(.detailed)
        model.select(model.engine.date(2026, 11, 1))
        model.events.update(month: model.month, engine: model.engine)
        try await finish()
        try await Task.sleep(for: .milliseconds(100))
        try await finish()
        presentation.controlsAnimationClock = false
        for (number, direction) in [(1, "long-opening"), (7, "switch-short"), (1, "switch-long"), (1, "long-closing"),
                                    (7, "short-opening"), (7, "short-closing"), (15, "cross-opening"),
                                    (8, "cross-earlier"), (22, "cross-later"), (8, "cross-back"), (8, "cross-closing")] {
            let date = model.engine.date(2026, 11, number)
            if direction == "short-opening" || direction == "cross-opening" {
                model.select(date)
                try await finish()
            }
            let button = try await visibleButton(for: date)
            let callbacks = presentation.driverCallbackCount
            let started = ProcessInfo.processInfo.systemUptime
            try require(button.accessibilityPerformPress(), "长日程未触发真实动画")
            let deadline = Date().addingTimeInterval(3)
            while presentation.isTransitioning || model.events.loading {
                try require(Date() < deadline, "长日程动画未及时完成")
                try await Task.sleep(for: .milliseconds(5))
            }
            try require(presentation.driverCallbackCount > callbacks && !presentation.hasActiveFrameDriver,
                        "日程真实刷新驱动未运行或未清理")
            if !direction.hasSuffix("closing") {
                let agenda = descendants(presentation.host.view).compactMap { $0 as? CalendarDayAgendaView }
                    .first { !$0.isHidden && $0.date == date }
                try require(agenda?.itemCount == (number == 1 ? 12 : 1), "切换日期后日程内容或高度未更新")
            }
            let timings = presentation.drawingMilliseconds.sorted()
            let stamps = presentation.displayTimestamps
            let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }.sorted()
            let trace = presentation.agendaFrameTrace
            try JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("agenda-frames-\(direction).json"))
            let draws = zip(trace.dropFirst(), trace).map { ($0["started"]! - $1["started"]!) * 1000 }.sorted()
            report.append(["scenario": direction, "drawnFrames": trace.count,
                "drawingIntervalP95MS": draws.isEmpty ? 0 : draws[min(draws.count - 1, draws.count * 95 / 100)],
                "drawingIntervalMaxMS": draws.last ?? 0, "handoffMS": presentation.handoffMilliseconds,
                "elapsedMS": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "callbacks": presentation.driverCallbackCount - callbacks,
                "preparationMS": presentation.preparationMilliseconds,
                "drawingMaxMS": timings.last ?? 0,
                "drawingP95MS": timings.isEmpty ? 0 : timings[min(timings.count - 1, timings.count * 95 / 100)],
                "callbackIntervalP95MS": intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, intervals.count * 95 / 100)]])
            if !capturesWindow { try save(presentation.view, "agenda-live-\(direction)") }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("agenda-animation.json"))
    }
}
#endif
