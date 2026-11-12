#if DEBUG
import AppKit
import DayOrderCore
import QuartzCore

@MainActor enum CalendarAgendaGenieSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL,
                       save: (NSView, String) throws -> Void) async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "DayOrder.AgendaGenie", code: 1,
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
                throw NSError(domain: "DayOrder.AgendaGenie", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "背景采样无法创建位图：\(type(of: view))，\(view.bounds)"])
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let x = Int((point.x - view.bounds.minX) * CGFloat(bitmap.pixelsWide) / view.bounds.width)
            let y = Int((point.y - view.bounds.minY) * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                throw NSError(domain: "DayOrder.AgendaGenie", code: 3, userInfo: [NSLocalizedDescriptionKey:
                    "背景采样像素不可读：\(type(of: view))，坐标=\(x),\(y)，位图=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)"])
            }
            let alpha = color.alphaComponent
            return [color.redComponent * alpha, color.greenComponent * alpha, color.blueComponent * alpha, alpha]
        }
        func windowImage(_ name: String) async throws -> NSBitmapImageRep {
            guard let window = presentation.view.window else { throw CocoaError(.coderInvalidValue) }
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(80))
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else {
                throw NSError(domain: "DayOrder.AgendaGenie", code: 4,
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
                try require(Date() < deadline, "日程曲面动画未及时就绪")
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
        let original = model.selection
        let pixelTolerance = 1 / (presentation.view.window?.backingScaleFactor ?? 2) + 0.001
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
            return CalendarEvent(id: "genie-\(day)", title: day == 1 ? "万圣节" : "立冬",
                start: start, end: start.addingTimeInterval(86400), allDay: true,
                color: .init(red: 0.95, green: 0.5, blue: 0.05), calendarTitle: "日程动画预览")
        }
        await source.configure(access: .fullAccess, values: events)
        model.events.choose(.detailed)
        var report: [[String: Any]] = []
        let capturesWindow = ProcessInfo.processInfo.arguments.contains("--capture-agenda-window")
        var captureAnchorWindow: NSWindow?
        if capturesWindow, let panel = presentation.view.window as? CalendarPanel,
           let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
            let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 24,
                width: 24, height: 24), styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            anchorWindow.isReleasedWhenClosed = false
            let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
            anchorWindow.contentView = anchor
            captureAnchorWindow = anchorWindow
            panel.show(anchoredTo: anchor)
        }
        defer { captureAnchorWindow?.close() }
        for style in ["light", "dark"] {
            defaults.set(style, forKey: "appearance")
            for number in [1, 7] {
                model.closeAgenda()
                let date = model.engine.date(2026, 11, number)
                model.select(date)
                try await finish()
                try await Task.sleep(for: .milliseconds(100))
                try await finish()
                guard let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayButton })
                    .first(where: { $0.date == date && !$0.visibleRect.isEmpty }) else { throw CocoaError(.coderInvalidValue) }
                let anchor = presentation.view.convert(button.bounds, from: button)
                let expectedOriginY = contentBottom(button) + 8
                let window = presentation.view.window!.frame
                var nativeColor: [CGFloat] = []
                var agendaFrame = NSRect.zero
                var screenProbes: [(Int, [CGFloat])] = []
                for direction in ["opening", "closing"] {
                    try require(button.accessibilityPerformPress(), "日期未触发日程曲面过渡")
                    try await ready()
                    try require(presentation.isPreparedForSampling, "日程曲面过渡未启动")
                    if direction == "opening" {
                        guard let agenda = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayAgendaView })
                            .first(where: { !$0.isHidden && $0.date == date }) else {
                            throw NSError(domain: "DayOrder.AgendaGenie", code: 3, userInfo: [NSLocalizedDescriptionKey:
                                "背景采样找不到展开后的原生日程：\(date)"])
                        }
                        if !capturesWindow {
                            nativeColor = try pixel(agenda, at: NSPoint(x: agenda.bounds.width * 0.85,
                                                                       y: agenda.bounds.height * 0.7))
                        }
                        agendaFrame = presentation.view.convert(agenda.bounds, from: agenda)
                    }
                    var previous: Double = direction == "opening" ? 0 : 1
                    for frame in 0...48 {
                        presentation.sampleGeometry(deltaTime: frame == 0 ? 0 : 1.0 / 120)
                        presentation.transitionView?.display()
                        guard let sample = presentation.eventModeCells.values.first(where: { $0["reveal"] != nil }) else {
                            throw NSError(domain: "DayOrder.AgendaGenie", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "日程仍使用普通下拉，缺少日期起点曲面"])
                        }
                        let progress = sample["reveal"]!
                        try require(abs(sample["originX"]! - anchor.midX) <= pixelTolerance
                            && abs(sample["originY"]! - expectedOriginY) <= pixelTolerance,
                                    "曲面起点未对齐整周内容下方 8 pt 的日程灰底顶部：预期=(\(anchor.midX), \(expectedOriginY))，实际=\(sample)，\(style)/\(number)/\(direction)/\(frame)")
                        try require(direction == "opening" ? progress >= previous : progress <= previous,
                                    "曲面展开或收起发生反向跳动")
                        try require(presentation.view.window!.frame == window, "曲面动画改变了窗口边界")
                        previous = progress
                        if frame % 2 == 0 {
                            if !capturesWindow { try save(presentation.view, "agenda-genie-\(style)-\(number)-\(direction)-\(frame)") }
                            report.append(["appearance": style, "day": number, "direction": direction,
                                           "frame": frame, "geometry": sample])
                        }
                        if frame == 8 { try require(progress > 0.05 && progress < 0.95, "曲面缺少可见中间态") }
                        if [8, 24, 48].contains(frame), progress * agendaFrame.height > 8, let overlay = presentation.transitionView {
                            let scale = overlay.window?.backingScaleFactor ?? 2
                            let top = ((expectedOriginY + (agendaFrame.minY - expectedOriginY) * progress) * scale).rounded() / scale
                            let spreadT = min(1, max(0, progress * (1 + 0.85 * sin(0.7 * .pi / 2))))
                            let spread = spreadT * spreadT * (3 - 2 * spreadT)
                            let width = sample["originWidth"]! + (agendaFrame.width - sample["originWidth"]!) * spread
                            let startX = anchor.midX - sample["originWidth"]! / 2
                            let left = startX + (agendaFrame.minX - startX) * spread
                            if !capturesWindow {
                                let color = try pixel(overlay, at: NSPoint(x: left + width * 0.85,
                                    y: top + agendaFrame.height * progress * 0.7))
                                let error = zip(color, nativeColor).map { abs($0 - $1) }.max()!
                                try require(error <= 2 / 255,
                                    "动画背景与原生日程颜色或透明度不一致：\(style)/\(number)/\(direction)/\(frame)，动画=\(color)，原生=\(nativeColor)")
                                report.append(["appearance": style, "day": number, "direction": direction,
                                    "frame": frame, "backgroundError": error, "nativeRGBA": nativeColor, "animatedRGBA": color])
                            }
                            if capturesWindow, direction == "opening", frame == 8 || frame == 48 {
                                let bitmap = try await windowImage("agenda-window-\(style)-\(number)-\(frame)")
                                screenProbes.append((frame, try windowPixel(bitmap, at: NSPoint(x: left + width * 0.85,
                                    y: top + agendaFrame.height * progress * 0.7))))
                            }
                        }
                    }
                    try await finish()
                    if capturesWindow, direction == "opening" {
                        let bitmap = try await windowImage("agenda-window-\(style)-\(number)-native")
                        let native = try windowPixel(bitmap, at: NSPoint(x: agendaFrame.minX + agendaFrame.width * 0.85,
                            y: agendaFrame.minY + agendaFrame.height * 0.7))
                        for (frame, animated) in screenProbes {
                            let error = zip(animated, native).map { abs($0 - $1) }.max()!
                            report.append(["appearance": style, "day": number, "frame": frame,
                                "windowNativeRGB": native, "windowAnimatedRGB": animated, "windowColorError": error])
                            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                                .write(to: directory.appendingPathComponent("agenda-genie.json"))
                            try require(error <= 3 / 255,
                                "真实窗口动画底色与原生详情不一致：\(style)/\(number)/\(frame)，动画=\(animated)，原生=\(native)")
                        }
                    }
                    let timings = presentation.drawingMilliseconds.sorted()
                    if !timings.isEmpty {
                        report.append(["appearance": style, "day": number, "direction": direction,
                                       "drawingMedianMS": timings[timings.count / 2],
                                       "drawingP95MS": timings[min(timings.count - 1, timings.count * 95 / 100)]])
                    }
                }
                // 活动动画反向保留已经绘出的曲面，不能从全开或全关重新开始。
                try require(button.accessibilityPerformPress(), "无法启动反向检查")
                try await ready()
                presentation.sampleGeometry(deltaTime: 0.07)
                presentation.transitionView?.display()
                let before = presentation.eventModeCells.values.compactMap { $0["reveal"] }.first!
                model.closeAgenda()
                try await ready()
                presentation.sampleGeometry(deltaTime: 0)
                presentation.transitionView?.display()
                let after = presentation.eventModeCells.values.compactMap { $0["reveal"] }.first!
                try require(abs(before - after) < 0.0001, "途中收起重置了曲面形状")
                try await finish()
                presentation.reduceMotionOverride = true
                try require(button.accessibilityPerformPress(), "无法启动减少动态效果检查")
                try await ready()
                presentation.sampleGeometry(deltaTime: 0.04)
                presentation.transitionView?.display()
                try require(presentation.eventModeSample == nil, "减少动态效果仍执行曲面扭曲")
                try await finish()
                model.closeAgenda()
                try await finish()
                presentation.reduceMotionOverride = false
            }
        }
        for mode in [CalendarEventDisplay.detailed, .compact, .dots] {
            for (scenario, values) in [("empty", [CalendarEvent]()), ("other-day", [events[1]])] {
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
                try require(button.eventMarkers.isEmpty, "起点场景未覆盖所选日期无标记")
                let expectedY = contentBottom(button) + 8
                let anchor = presentation.view.convert(button.bounds, from: button)
                for direction in ["opening", "closing"] {
                    try require(button.accessibilityPerformPress(), "起点场景未触发动画")
                    try await ready()
                    presentation.sampleGeometry(deltaTime: 0.06)
                    presentation.transitionView?.display()
                    guard let sample = presentation.eventModeCells.values.first(where: { $0["reveal"] != nil }) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    try require(abs(sample["originY"]! - expectedY) <= pixelTolerance
                        && abs(sample["originX"]! - anchor.midX) <= pixelTolerance,
                        "无标记或同周其他日有标记时，动画未复用灰底顶部：\(mode)/\(scenario)/\(direction)")
                    try save(presentation.view, "agenda-genie-origin-\(mode)-\(scenario)-\(direction)")
                    report.append(["mode": "\(mode)", "scenario": scenario, "direction": direction,
                                   "expectedOriginY": expectedY, "geometry": sample])
                    try await finish()
                }
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("agenda-genie.json"))
    }
}
#endif
