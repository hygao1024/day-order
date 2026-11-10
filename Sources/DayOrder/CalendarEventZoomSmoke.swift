#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarEventZoomSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL,
                       month: Int, save: (NSView, String) throws -> Void) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "DayOrder.EventZoom", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() {
                try require(Date() < deadline, "日程月年切换未及时就绪")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func finish() {
            presentation.sampleGeometry(deltaTime: 1)
            presentation.finishGeometrySampling()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func pixelError(_ first: NSImage, _ second: NSImage) throws -> Double {
            guard let a = first.representations.first as? NSBitmapImageRep,
                  let b = second.representations.first as? NSBitmapImageRep,
                  a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { throw CocoaError(.coderInvalidValue) }
            var error = 0.0
            for y in 0..<a.pixelsHigh {
                for x in 0..<a.pixelsWide {
                    guard let c = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let d = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw CocoaError(.coderInvalidValue) }
                    error += abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent)
                        + abs(c.blueComponent - d.blueComponent)
                }
            }
            return error * 255 / Double(a.pixelsWide * a.pixelsHigh * 3)
        }
        func longestBlackRun(_ image: NSImage) throws -> Int {
            guard let bitmap = image.representations.first as? NSBitmapImageRep else { throw CocoaError(.coderInvalidValue) }
            var longest = 0
            for y in 0..<bitmap.pixelsHigh {
                var run = 0
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent > 0.9 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.03 {
                        run += 1
                        longest = max(longest, run)
                    } else { run = 0 }
                }
            }
            return longest
        }
        func titleInk(_ image: NSImage, rect: CGRect) throws -> Int {
            guard let bitmap = image.representations.first as? NSBitmapImageRep else { throw CocoaError(.coderInvalidValue) }
            let scaleX = CGFloat(bitmap.pixelsWide) / image.size.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / image.size.height
            var ink = 0
            for y in max(0, Int(rect.minY * scaleY))..<min(bitmap.pixelsHigh, Int(ceil(rect.maxY * scaleY))) {
                for x in max(0, Int(rect.minX * scaleX))..<min(bitmap.pixelsWide, Int(ceil(rect.maxX * scaleX))) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent - color.blueComponent > 0.3 { ink += 1 }
                }
            }
            return ink
        }
        func iconError(_ direct: NSImage, _ replay: NSImage, rect: CGRect, date: String) throws -> Double {
            guard let a = direct.representations.first as? NSBitmapImageRep,
                  let b = replay.representations.first as? NSBitmapImageRep else { throw CocoaError(.coderInvalidValue) }
            let scale = CGFloat(b.pixelsWide) / replay.size.width
            var errors = Array(repeating: 0.0, count: 9)
            var count = 0
            var white = 0
            var cutouts = 0
            var replayWhite = 0
            var replayCutouts = 0
            for y in Int(ceil(rect.minY * scale))..<Int(rect.maxY * scale) {
                for x in Int(ceil(rect.minX * scale))..<Int(rect.maxX * scale) {
                    let ax = Int((CGFloat(x) + 0.5) / CGFloat(b.pixelsWide) * CGFloat(a.pixelsWide))
                    let ay = Int((CGFloat(y) + 0.5) / CGFloat(b.pixelsHigh) * CGFloat(a.pixelsHigh))
                    guard let original = a.colorAt(x: ax, y: ay)?.usingColorSpace(.deviceRGB),
                          let rendered = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw CocoaError(.coderInvalidValue) }
                    // 日期格的屏幕像素相位与独立 PDF 回放不同，最多对齐一个回放像素。
                    for dy in -1...1 {
                        for dx in -1...1 {
                            guard let shifted = b.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.deviceRGB) else { throw CocoaError(.coderInvalidValue) }
                            errors[(dy + 1) * 3 + dx + 1] += abs(original.redComponent - shifted.redComponent)
                                + abs(original.greenComponent - shifted.greenComponent)
                                + abs(original.blueComponent - shifted.blueComponent)
                        }
                    }
                    if original.blueComponent > 0.8 { white += 1 }
                    if original.redComponent - original.blueComponent > 0.5 { cutouts += 1 }
                    if rendered.blueComponent > 0.8 { replayWhite += 1 }
                    if rendered.redComponent - rendered.blueComponent > 0.5 { replayCutouts += 1 }
                    count += 1
                }
            }
            try require(count > 0 && white > 0 && cutouts > 0,
                        "日程图标缺少白色线条或镂空细节：\(date)，白色=\(white)，镂空=\(cutouts)，原图=\(a.pixelsWide)×\(a.pixelsHigh)，回放=\(b.pixelsWide)×\(b.pixelsHigh)")
            try require(replayWhite > 0 && replayCutouts > 0, "日程 PDF 回放丢失图标镂空或白色线条")
            return errors.min()! / Double(count * 3)
        }
        let selection = model.selection
        let today = model.today
        let appearance = defaults.object(forKey: "appearance")
        presentation.controlsAnimationClock = true
        presentation.reduceMotionOverride = false
        defer {
            presentation.cancelTransition()
            presentation.controlsAnimationClock = false
            presentation.reduceMotionOverride = nil
            model.dismissYearLevel()
            model.events.choose(.hidden)
            model.today = today
            model.select(selection)
            defaults.set(appearance, forKey: "appearance")
        }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let monthStart = model.engine.date(2026, month, 1)
        let dayCount = model.engine.calendar.range(of: .day, in: .month, for: monthStart)!.count
        let values = [(1, "车贷"), (7, "白露"), (10, "教师节活动安排"), (20, "社区交流会议"),
                      (25, "家庭聚餐"), (dayCount, "末周回归日程")]
            .map { day, title in
                let start = local.date(from: DateComponents(year: 2026, month: month, day: day, hour: 10))!
                return CalendarEvent(id: "zoom-\(day)", title: title, start: start, end: start.addingTimeInterval(3600),
                                     allDay: false, color: .init(red: 0.9, green: 0.45, blue: 0.1))
            }
        await source.configure(access: .fullAccess, values: values)
        model.today = model.engine.date(2026, month, dayCount)
        model.select(model.engine.date(2026, month, 7))
        model.events.choose(.detailed)
        try await wait { !model.events.loading && presentation.isPreparedForSampling }
        finish()
        var report: [[String: Any]] = []
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            try await Task.sleep(for: .milliseconds(100))
            try save(presentation.view, "event-zoom-\(appearance)-live")
            let buttons = descendants(presentation.host.view).compactMap { $0 as? CalendarDayButton }
                .filter { !$0.visibleRect.isEmpty && !$0.events.isEmpty }
            try require(buttons.count >= values.count, "月年切换缺少长短日程样本")
            for button in buttons {
                let pdf = NSImage(data: button.dataWithPDF(inside: button.bounds))!
                guard let replay = CalendarSnapshotImage.rasterized(pdf, scale: 2),
                      let direct = CalendarSnapshotImage.capture(button, in: button.bounds) else { throw CocoaError(.coderInvalidValue) }
                let directRun = try longestBlackRun(direct)
                let replayRun = try longestBlackRun(replay)
                try require(replayRun <= max(12, directRun), "日程 PDF 回放出现原视图没有的黑块")
                var maxIconError = 0.0
                for marker in button.eventMarkers {
                    let frame = marker.style.frame
                    let icon = CGRect(x: frame.minX + 2.5, y: frame.midY - 3.5, width: 7, height: 7)
                    let error = try iconError(direct, replay, rect: icon, date: button.title)
                    try require(error < 0.08, "日程 PDF 回放丢失图标镂空：像素误差=\(error)")
                    maxIconError = max(maxIconError, error)
                    let title = CGRect(x: frame.minX + 12, y: frame.minY, width: frame.width - 14, height: frame.height)
                    let directInk = try titleInk(direct, rect: title)
                    let replayInk = try titleInk(replay, rect: title)
                    try require(directInk > 3 && Double(replayInk) >= Double(directInk) * 0.6,
                                "日程 PDF 回放丢失标题文字")
                }
                report.append(["appearance": appearance, "date": button.title,
                               "directBlackRun": directRun, "pdfBlackRun": replayRun, "iconPixelError": maxIconError])
            }
            for direction in ["out", "in"] {
                if direction == "out" { model.openYearOverview() }
                else {
                    guard let button = descendants(presentation.host.view).compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == "2026年\(month)月" }), button.accessibilityPerformPress() else {
                        throw CocoaError(.coderInvalidValue)
                    }
                }
                try await wait { presentation.isPreparedForSampling }
                for index in 0...72 {
                    presentation.sampleGeometry(deltaTime: index == 0 ? 0 : 1.0 / 120)
                    if [0, 6, 12, 24, 72].contains(index) {
                        // 重定向起点的画布透明度可以为零，开始运动后必须使用缩放画布。
                        if index > 0 {
                            try require(presentation.canvasSample != nil, "日程月年切换未经过缩放画布")
                        }
                        try save(presentation.view, "event-zoom-\(appearance)-\(direction)-\(index)")
                        guard let view = presentation.transitionView,
                              let image = CalendarSnapshotImage.capture(view, in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
                        let run = try longestBlackRun(image)
                        try require(run <= 24, "月年切换中间帧出现连续黑块")
                        report.append(["appearance": appearance, "direction": direction, "frame": index, "blackRun": run])
                    }
                }
                var lastWeek: (CGRect, NSImage)?
                if direction == "in" {
                    presentation.sampleGeometry(deltaTime: 1)
                    presentation.transitionView?.display()
                    try require(presentation.canvasSample?["dateCount"] == Double(dayCount),
                                "月年动画末帧缺少本月日期：月份=\(month)，应有=\(dayCount)，实际=\(presentation.canvasSample?["dateCount"] ?? -1)")
                    guard let table = descendants(presentation.host.view).compactMap({ $0 as? NSTableView })
                        .first(where: { $0.identifier?.rawValue == "calendarTimeline" }),
                          let weeks = model.calendarTimeline(firstWeekday: 1).weekRows(inMonth: monthStart) else { throw CocoaError(.coderInvalidValue) }
                    let area = presentation.view.convert(table.rect(ofRow: weeks.upperBound - 1), from: table)
                        .insetBy(dx: CalendarTimelineView.contentInset, dy: 1)
                    guard let before = CalendarSnapshotImage.capture(presentation.view, in: area) else { throw CocoaError(.coderInvalidValue) }
                    lastWeek = (area, before)
                    try save(presentation.view, "event-zoom-\(appearance)-before-handoff")
                }
                finish()
                if let (area, before) = lastWeek {
                    try await Task.sleep(for: .milliseconds(100))
                    guard let after = CalendarSnapshotImage.capture(presentation.view, in: area) else { throw CocoaError(.coderInvalidValue) }
                    let error = try pixelError(before, after)
                    try require(error < 5, "月年交接时最后一周出现补绘：月份=\(month)，像素误差=\(error)")
                    report.append(["appearance": appearance, "lastWeekHandoffError": error, "days": dayCount])
                }
            }
            try save(presentation.view, "event-zoom-\(appearance)-returned")
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("event-zoom-pixels.json"))
    }
}
#endif
