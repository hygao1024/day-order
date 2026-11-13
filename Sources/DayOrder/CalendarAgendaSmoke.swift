#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarAgendaSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL,
                       save: (NSView, String) throws -> Void) async throws {
        try await CalendarAgendaAnimationSmoke.verify(model: model, presentation: presentation,
            source: source, defaults: defaults, directory: directory, save: save)
        try await CalendarDayFeedbackSmoke.verify(engine: model.engine, directory: directory, save: save)
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DayOrder.Agenda", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func geometry(_ view: NSView) -> String {
            var value: NSView? = view
            var result: [String] = []
            while let current = value {
                result.append("\(type(of: current)): frame=\(current.frame), bounds=\(current.bounds)")
                value = current.superview
            }
            return result.joined(separator: "\n")
        }
        func wait(_ condition: () -> Bool) async throws {
            let end = Date().addingTimeInterval(5)
            while !condition() {
                try require(Date() < end, "当天日程未及时就绪：过渡=\(presentation.isTransitioning)，读取=\(model.events.loading)")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func finish() async throws {
            try await wait { !model.events.loading && (!presentation.isTransitioning || presentation.isPreparedForSampling) }
            if presentation.isPreparedForSampling {
                presentation.sampleGeometry(deltaTime: 1)
                presentation.finishGeometrySampling()
            }
            presentation.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        var testMonth = 10
        func day(_ number: Int) throws -> CalendarDayButton {
            let date = model.engine.date(2026, testMonth, number)
            guard let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayButton })
                .first(where: { $0.date == date && !$0.visibleRect.isEmpty }) else { throw CocoaError(.coderInvalidValue) }
            return button
        }
        func agenda() throws -> CalendarDayAgendaView {
            let views = descendants(presentation.host.view).compactMap { $0 as? CalendarDayAgendaView }.filter { !$0.isHidden }
            try require(views.count == 1, "展开详情不是唯一一份：\(views.count)")
            return views[0]
        }
        func click(_ number: Int) throws { try require(try day(number).accessibilityPerformPress(), "日期按钮未执行") }
        let original = model.selection
        let today = model.today
        presentation.controlsAnimationClock = true
        presentation.reduceMotionOverride = false
        defer {
            presentation.cancelTransition()
            presentation.controlsAnimationClock = false
            presentation.reduceMotionOverride = nil
            model.closeAgenda()
            model.events.choose(.hidden)
            model.today = today
            model.select(original)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func start(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        }
        var values: [CalendarEvent] = []
        for index in 0..<12 {
            let title = index == 2 ? "产品方案评审：核对下一阶段交互设计与上线安排"
                : ["信用卡还款", "团队晨会", "方案评审", "项目讨论"][index % 4]
            let began = start(13, index == 0 ? 0 : 8 + index)
            values.append(CalendarEvent(id: "agenda-\(index)", title: title, start: began,
                end: began.addingTimeInterval(index == 0 ? 86400 : 1800), allDay: index == 0,
                color: .init(red: 0.3, green: 0.45, blue: 0.95), calendarTitle: "工作日历"))
        }
        values.append(CalendarEvent(id: "next-day", title: "阅读", start: start(14, 10), end: start(14, 11),
                                    allDay: false, color: .init(red: 0.7, green: 0.3, blue: 0.8), calendarTitle: "个人日历"))
        await source.configure(access: .fullAccess, values: values)
        model.today = model.engine.date(2026, 10, 6)
        model.select(model.today)
        model.events.choose(.detailed)
        try await finish()
        try await wait { model.calendarSnappedMonth == model.month }
        var report: [[String: Any]] = []
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            try await Task.sleep(for: .milliseconds(100))
            try click(13)
            try require(model.selection == model.engine.date(2026, 10, 13) && model.agenda == nil, "首次点击没有只选择日期")
            try await finish()
            try await Task.sleep(for: .milliseconds(100))
            // 保留三个屏幕像素的浏览偏移，展开不能偷偷重新吸附到月首。
            let timelineScroll = try day(13).enclosingScrollView!
            let scale = timelineScroll.window?.backingScaleFactor ?? 2
            let offset = (timelineScroll.contentView.bounds.minY * scale).rounded() / scale + 3 / scale
            timelineScroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            timelineScroll.reflectScrolledClipView(timelineScroll.contentView)
            presentation.view.display()
            let before = presentation.view.convert(try day(13).bounds, from: try day(13))
            let beforeGeometry = geometry(try day(13))
            let height = presentation.preferredContentSize.height
            let windowFrame = presentation.view.window!.frame
            let viewportSize = timelineScroll.bounds.size
            let footerFrame = presentation.shell!.footer.convert(presentation.shell!.footer.bounds, to: presentation.view)
            func requireFixedWindow() throws {
                try require(abs(presentation.preferredContentSize.height - height) < 0.5
                            && presentation.view.window!.frame == windowFrame
                            && timelineScroll.bounds.size == viewportSize,
                            "展开或收起日程改变了窗口或日历可视区大小")
                try require(presentation.shell!.footer.convert(presentation.shell!.footer.bounds, to: presentation.view) == footerFrame,
                            "展开或收起日程移动了底部日期详情")
            }
            let table = timelineScroll.documentView as! NSTableView
            let timeline = model.calendarTimeline(firstWeekday: 1)
            let selectedRow = timeline.weekRow(containing: model.selection, inMonth: model.month)
            let nextWeekOffset = table.rect(ofRow: selectedRow + 1).minY - table.rect(ofRow: selectedRow).minY
            try click(13)
            try await wait { presentation.isPreparedForSampling }
            for _ in 0..<24 {
                presentation.sampleGeometry(deltaTime: 1.0 / 120)
                try requireFixedWindow()
            }
            try save(presentation.view, "agenda-\(appearance)-opening")
            try require(presentation.eventModeSample != nil, "展开没有复用日期布局动画")
            try await finish()
            let view = try agenda()
            let expandedHeight = view.bounds.height
            presentation.view.display()
            let after = presentation.view.convert(try day(13).bounds, from: try day(13))
            try require(abs(before.minY - after.minY) < 0.5,
                        "展开移动了选中日期：\(before) → \(after)\n起点：\(beforeGeometry)\n终点：\(geometry(try day(13)))")
            try require(view.itemCount == 12, "完整日程数量错误")
            try require(view.itemCount == 12 && view.scroll.documentView!.subviews.count < 12, "日程列表被截断")
            try require(view.scroll.contentSize.height <= CalendarDayAgendaLayout.bodyLimit + 1, "列表没有限制高度")
            try requireFixedWindow()
            let addedHeight = table.rect(ofRow: selectedRow + 1).minY - table.rect(ofRow: selectedRow).minY - nextWeekOffset
            try require(addedHeight > 0 && addedHeight <= expandedHeight
                        && abs(view.frame.maxY - view.superview!.bounds.height) < 0.5,
                        "后续周行没有按日程净新增高度下移，或卡片下方残留空白")
            let outer = try day(13).enclosingScrollView!
            let outerOrigin = outer.contentView.bounds.origin
            let fixedRemaining = presentation.view.convert(view.remaining.bounds, from: view.remaining)
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -180, wheel2: 0, wheel3: 0)!
            view.scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
            try require(view.scroll.contentView.bounds.minY > 0 && outer.contentView.bounds.origin == outerOrigin,
                        "内层滚动带动了月份或没有滚动")
            try require(presentation.view.convert(view.remaining.bounds, from: view.remaining) == fixedRemaining, "滚动移动了剩余数量提示")
            try save(presentation.view, "agenda-\(appearance)-scrolled")
            let end = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10000, wheel2: 0, wheel3: 0)!
            view.scroll.scrollWheel(with: NSEvent(cgEvent: end)!)
            try require(view.remaining.stringValue == "已显示全部日程"
                        && outer.contentView.bounds.origin == outerOrigin, "列表底部不可达或向外传递滚动")
            view.scroll.contentView.scroll(to: .zero)
            view.scroll.reflectScrolledClipView(view.scroll.contentView)
            try save(presentation.view, "agenda-\(appearance)-expanded")
            try click(14)
            try await finish()
            try require(try agenda().scroll.accessibilityLabel() == "10月14日 · 1项日程", "展开后没有跟随新日期")
            try require(try agenda().scroll.contentView.bounds.minY == 0, "切日沿用了旧滚动位置")
            try require(try agenda().bounds.height < expandedHeight, "少量日程没有自适应高度")
            try click(15)
            try await finish()
            try require(descendants(try agenda()).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "当天暂无日程" }, "空日程缺少明确状态")
            try click(15)
            try await finish()
            try require(model.agenda == nil, "再次点击空日程日期未收起")
            try click(13)
            try click(13)
            try await finish()
            try click(13)
            try await finish()
            try require(model.agenda == nil, "再次点击未收起")
            try requireFixedWindow()
            try require(abs(table.rect(ofRow: selectedRow + 1).minY - table.rect(ofRow: selectedRow).minY
                            - nextWeekOffset) < 0.5, "收起后周行没有归位")
            report.append(["appearance": appearance, "dateYError": abs(before.minY - after.minY), "items": 12])
            try click(14)
        }
        var rowReport: [[String: Any]] = []
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            model.closeAgenda()
            model.select(model.engine.date(2026, 10, 13))
            try await finish()
            try click(13)
            try await finish()
            for count in 1...3 {
                let events = values.prefix(count).enumerated().map { index, event in
                    CalendarEvent(id: event.id, title: index == 0 ? "小孟同学’s 第28 Chinese Birthday" : event.title,
                        start: event.start, end: event.end, allDay: event.allDay, color: event.color,
                        calendarTitle: event.calendarTitle)
                }
                await source.configure(access: .fullAccess, values: events)
                model.events.update(month: model.month, engine: model.engine)
                try await finish()
                let view = try agenda()
                let rows = view.scroll.documentView!.subviews.sorted { $0.frame.minY < $1.frame.minY }
                try require(rows.count == count && Set(rows.map { $0.bounds.height }).count == 1,
                            "单行日程没有采用一致行高")
                guard let title = descendants(rows[0]).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.stringValue == events[0].title }),
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
                try require(title.maximumNumberOfLines == 1 && title.bounds.height <= 16
                            && title.toolTip == events[0].title, "长标题仍换行或丢失完整标题")
                try save(presentation.view, "agenda-rows-\(appearance)-\(count)")
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
                func color(_ point: NSPoint) throws -> NSColor {
                    guard let color = bitmap.colorAt(x: Int(point.x * scaleX), y: Int(point.y * scaleY))?
                        .usingColorSpace(.deviceRGB) else { throw CocoaError(.coderInvalidValue) }
                    return color
                }
                var separators = 0
                for (index, row) in rows.enumerated() {
                    let frame = view.convert(row.bounds, from: row)
                    let bottom = try color(NSPoint(x: frame.minX + 20, y: frame.maxY - 0.25))
                    let above = try color(NSPoint(x: frame.minX + 20, y: frame.maxY - 2))
                    let difference = abs(bottom.redComponent - above.redComponent)
                        + abs(bottom.greenComponent - above.greenComponent) + abs(bottom.blueComponent - above.blueComponent)
                        + abs(bottom.alphaComponent - above.alphaComponent)
                    let hasLine = difference > 0.03
                    try require(hasLine == (index < count - 1), "日程分隔线位置错误：\(appearance)，\(count)项，第\(index + 1)项，色差=\(difference)")
                    if hasLine { separators += 1 }
                }
                if count == 2 {
                    try CalendarAgendaTitleSmoke.verify(title: title, root: presentation.view,
                        name: "\(appearance)-long", save: save)
                    guard let shortTitle = descendants(rows[1]).compactMap({ $0 as? NSTextField })
                        .first(where: { $0.stringValue == events[1].title }) else { throw CocoaError(.coderInvalidValue) }
                    try CalendarAgendaTitleSmoke.verify(title: shortTitle, root: presentation.view,
                        name: "\(appearance)-short", save: save)
                }
                rowReport.append(["appearance": appearance, "count": count, "separators": separators])
            }
            let probe = CalendarEvent(id: "fade-probe", title: String(repeating: "█", count: 40),
                start: values[0].start, end: values[0].end, allDay: true, color: values[0].color)
            await source.configure(access: .fullAccess, values: [probe])
            model.events.update(month: model.month, engine: model.engine)
            try await finish()
            guard let field = descendants(try agenda()).compactMap({ $0 as? NSTextField })
                .first(where: { $0.stringValue == probe.title }),
                  let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { throw CocoaError(.coderInvalidValue) }
            field.cacheDisplay(in: field.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / field.bounds.width
            func peakAlpha(x: CGFloat) -> CGFloat {
                (bitmap.pixelsHigh / 3..<bitmap.pixelsHigh * 2 / 3).map {
                    bitmap.colorAt(x: Int(x * scale), y: $0)?.alphaComponent ?? 0
                }.max() ?? 0
            }
            let solid = peakAlpha(x: field.bounds.maxX - 22)
            let tail = peakAlpha(x: field.bounds.maxX - 3)
            try require(solid > 0.5 && tail < solid * 0.3, "长标题右端未渐隐：\(appearance)，正文=\(solid)，尾部=\(tail)")
            rowReport.append(["appearance": appearance, "solidAlpha": solid, "tailAlpha": tail])
        }
        try JSONSerialization.data(withJSONObject: rowReport, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("agenda-rows.json"))
        // 整周的实际标记决定留白，所选日为空也必须给同周其他日及跨日段留空间。
        var spacingReport: [[String: Any]] = []
        let single = values[1]
        let otherDay = values.last!
        let span = CalendarEvent(id: "spacing-span", title: "跨日安排", start: start(12, 0), end: start(15, 0),
            allDay: true, color: single.color)
        let scenarios: [(String, [CalendarEvent], CGFloat)] = [
            ("empty", [], 45.5), ("one", [single, otherDay], 61),
            ("two-other-day", [otherDay, CalendarEvent(id: "second", title: "另一项安排",
                start: start(14, 12), end: start(14, 13), allDay: false, color: single.color)], 75),
            ("overflow", Array(values.prefix(3)), 75), ("span", [span, otherDay], 75)
        ]
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            for mode in [CalendarEventDisplay.detailed, .compact, .dots] {
                model.closeAgenda()
                model.events.choose(mode)
                model.select(model.engine.date(2026, 10, 13))
                try await finish()
                let button = try day(13)
                let dateTop = button.frame.minY
                let windowFrame = presentation.view.window!.frame
                try click(13)
                try await finish()
                for (name, events, detailedBottom) in scenarios {
                    await source.configure(access: .fullAccess, values: events)
                    model.events.update(month: model.month, engine: model.engine)
                    try await finish()
                    let view = try agenda()
                    let week = view.superview!
                    let buttons = week.subviews.compactMap { $0 as? CalendarDayButton }
                    let markerBottom = buttons.flatMap(\.eventMarkers).map { $0.style.frame.maxY }.max() ?? 0
                    let bottom = max(button.focusRingMaskBounds.maxY, markerBottom)
                    let gap = view.frame.minY - dateTop - bottom
                    let pixel = 1 / (view.window?.backingScaleFactor ?? 2)
                    try require(abs(gap - 4) <= pixel + 0.001, "详情与整周内容间距错误：\(appearance)/\(mode)/\(name)，\(gap)")
                    if mode == .detailed {
                        try require(abs(bottom - detailedBottom) < 0.5, "间距场景未覆盖预期标记行数：\(name)")
                    }
                    try require(buttons.allSatisfy { abs($0.frame.minY - dateTop) <= pixel + 0.001 && $0.frame.maxY <= view.frame.minY }
                                && presentation.view.window!.frame == windowFrame,
                                "收紧间距移动日期、覆盖标记或改变窗口大小")
                    try require(abs(view.frame.maxY - week.bounds.height) < 0.5, "空白被搬到了详情下方")
                    spacingReport.append(["appearance": appearance, "mode": String(describing: mode),
                                          "scenario": name, "gap": gap, "contentBottom": bottom])
                    if mode == .detailed { try save(presentation.view, "agenda-spacing-\(appearance)-\(name)") }
                }
            }
        }
        try JSONSerialization.data(withJSONObject: spacingReport, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("agenda-spacing.json"))
        model.closeAgenda()
        model.events.choose(.detailed)
        try await finish()
        // 自由浏览时，展开后完全离开视口的周行也必须平移，不能当成删除元素淡出。
        testMonth = 12
        defaults.set(1, forKey: "firstWeekday")
        let december = model.engine.date(2026, 12, 1)
        let eventStart = calendar.date(from: DateComponents(year: 2026, month: 12, day: 7, hour: 10))!
        await source.configure(access: .fullAccess, values: [CalendarEvent(id: "edge", title: "十二月日程",
            start: eventStart, end: eventStart.addingTimeInterval(3600), allDay: false,
            color: .init(red: 0.6, green: 0.3, blue: 0.8), calendarTitle: "工作日历")])
        model.select(model.engine.date(2026, 12, 7))
        try await finish()
        let edgeScroll = try day(7).enclosingScrollView as! CalendarTimelineScrollView
        let edgeTable = edgeScroll.documentView as! NSTableView
        let edgeTimeline = model.calendarTimeline(firstWeekday: 1)
        let firstRow = edgeTimeline.weekRow(containing: december, inMonth: december)
        let nearID = edgeTimeline.weekRow(containing: model.engine.date(2026, 12, 13), inMonth: december) * 8
        let farID = edgeTimeline.weekRow(containing: model.engine.date(2026, 12, 20), inMonth: december) * 8
        var edgeReport: [[String: Any]] = []
        for appearance in ["light", "dark"] {
            defaults.set(appearance, forKey: "appearance")
            edgeScroll.onActivity?()
            edgeScroll.contentView.scroll(to: NSPoint(x: 0, y: edgeTable.rect(ofRow: firstRow).minY - 150))
            edgeScroll.reflectScrolledClipView(edgeScroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            presentation.view.display()
            try require(try day(20).visibleRect.height > 0, "边缘回归缺少初始可见的 20–26 日")
            for direction in ["opening", "closing"] {
                try click(7)
                try await wait { presentation.isPreparedForSampling }
                presentation.sampleGeometry(deltaTime: 0)
                presentation.transitionView?.display()
                let initial = presentation.eventModeCells
                guard let nearStart = initial[nearID]?["y"], let farStart = initial[farID]?["y"] else {
                    throw NSError(domain: "DayOrder.Agenda", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "视口外周行缺少动画起点"])
                }
                for frame in 1...18 {
                    presentation.sampleGeometry(deltaTime: 1.0 / 120)
                    presentation.transitionView?.display()
                    let cells = presentation.eventModeCells
                    guard let near = cells[nearID], let far = cells[farID] else { throw CocoaError(.coderInvalidValue) }
                    let nearMove = near["y"]! - nearStart
                    let farMove = far["y"]! - farStart
                    try require(abs(nearMove - farMove) < 0.5 && far["opacity"]! > 0.99,
                                "边缘周行没有同向移动或发生淡出：方向=\(direction)，帧=\(frame)，近行=\(nearMove)，远行=\(farMove)，透明度=\(far["opacity"]!)")
                    if frame == 12 {
                        try require(direction == "opening" ? farMove > 20 : farMove < -20, "边缘周行没有实际移动")
                        try save(presentation.view, "agenda-edge-\(appearance)-\(direction)")
                        edgeReport.append(["appearance": appearance, "direction": direction,
                                           "nearMove": nearMove, "farMove": farMove, "opacity": far["opacity"]!])
                    }
                }
                try await finish()
                if direction == "opening" {
                    let view = try agenda()
                    let farFrame = presentation.view.convert(edgeTable.rect(ofRow: farID / 8), from: edgeTable)
                    let viewport = presentation.view.convert(edgeScroll.bounds, from: edgeScroll)
                    try require(farFrame.minY >= viewport.maxY && view.bounds.height > 0,
                                "边缘回归未覆盖展开后完全移出视口的周行")
                }
            }
        }
        try JSONSerialization.data(withJSONObject: edgeReport, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("agenda-edge.json"))
        for (month, number, weekday) in [(2, 28, 2), (8, 31, 1)] {
            testMonth = month
            defaults.set(weekday, forKey: "firstWeekday")
            let date = model.engine.date(2026, month, number)
            let began = calendar.date(from: DateComponents(year: 2026, month: month, day: number, hour: 23))!
            let span = CalendarEvent(id: "last-week", title: "跨日项目交接", start: began,
                end: began.addingTimeInterval(7200), allDay: false,
                color: .init(red: 0.3, green: 0.45, blue: 0.95), calendarTitle: "项目日历")
            await source.configure(access: .fullAccess, values: [span])
            model.closeAgenda()
            model.select(date)
            try await finish()
            try await Task.sleep(for: .milliseconds(100))
            let windowFrame = presentation.view.window!.frame
            let outer = try day(number).enclosingScrollView!
            try click(number)
            try await finish()
            let view = try agenda()
            try require(presentation.view.window!.frame == windowFrame, "月末展开改变了窗口大小")
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -300, wheel2: 0, wheel3: 0)!
            outer.scrollWheel(with: NSEvent(cgEvent: scroll)!)
            try await Task.sleep(for: .milliseconds(500))
            presentation.view.display()
            try require(view.visibleRect.height >= view.bounds.height - 1, "滚动日历后仍无法查看完整月末日程")
            try require(presentation.view.window!.frame == windowFrame, "滚动查看日程改变了窗口大小")
            try require(view.itemCount == 1, "月末查询或日程归属错误")
            try save(presentation.view, "agenda-last-week-\(month)")
            model.openYearOverview()
            try await finish()
            try require(model.agenda?.date == date, "进入年概览丢失展开状态")
            model.dismissYearLevel()
            try await finish()
            try require(try agenda().scroll.accessibilityLabel() == "\(month)月\(number)日 · 1项日程", "年概览返回未恢复原详情")
        }
        testMonth = 10
        model.select(model.engine.date(2026, 10, 14))
        try await finish()
        // 隐藏模式不通过展开入口绕过权限与数据边界。
        model.events.choose(.hidden)
        try await finish()
        let counts = await source.counters()
        try click(14)
        try click(14)
        try await Task.sleep(for: .milliseconds(100))
        let hiddenCounts = await source.counters()
        try require(model.agenda == nil && model.events.days.isEmpty && hiddenCounts == counts,
                    "隐藏模式通过日期点击读取了日程")
        await source.configure(access: .fullAccess, values: [])
        await source.holdRead()
        model.events.choose(.detailed)
        let deadline = Date().addingTimeInterval(5)
        while !(await source.hasHeldRead) {
            try require(Date() < deadline, "未挂起系统日程读取")
            try await Task.sleep(for: .milliseconds(10))
        }
        do {
            try await wait { presentation.isPreparedForSampling }
            presentation.sampleGeometry(deltaTime: 1)
            presentation.finishGeometrySampling()
            try click(14)
            try await wait { presentation.isPreparedForSampling }
            presentation.sampleGeometry(deltaTime: 1)
            presentation.finishGeometrySampling()
            try require(descendants(try agenda()).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "正在读取日程…" },
                        "读取中被误显示为空日程")
            model.closeAgenda()
            model.events.choose(.hidden)
            await source.finishRead(values)
            try await finish()
            try require(model.agenda == nil && model.events.days.isEmpty, "迟到读取重新打开日程或恢复隐藏数据")
        } catch {
            await source.finishRead([])
            throw error
        }
        await source.configure(access: .fullAccess, failing: true)
        model.events.choose(.detailed)
        try await finish()
        try click(14)
        try await finish()
        try require(descendants(try agenda()).compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == model.events.errorMessage }, "读取失败被误显示为空日程")
        model.closeAgenda()
        try await finish()
        await source.configure(access: .fullAccess, values: values)
        model.events.update(month: model.month, engine: model.engine)
        try await finish()
        try click(13)
        try click(13)
        try await wait { presentation.isPreparedForSampling }
        presentation.sampleGeometry(deltaTime: 0.08)
        try click(13)
        try click(13)
        try await finish()
        try require(try agenda().itemCount == 12, "快速反向丢失最终展开状态")
        await source.configure(access: .fullAccess, values: Array(values.prefix(2)))
        model.events.update(month: model.month, engine: model.engine)
        try await finish()
        try require(try agenda().itemCount == 2
                    && agenda().scroll.documentView?.subviews.count == 2, "展开列表没有刷新删除后的日程")
        model.showingSettings = true
        try await finish()
        try require(model.agenda?.date == model.selection, "进入设置丢失展开状态")
        model.showingSettings = false
        try await finish()
        try require(try agenda().scroll.accessibilityLabel() == "10月13日 · 2项日程", "设置返回未恢复原详情")
        model.closeAgenda()
        try await finish()
        presentation.reduceMotionOverride = true
        try click(13)
        try await finish()
        try require(try agenda().itemCount == 2, "减少动态效果没有展示详情")
        guard let window = presentation.view.window,
              let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                  isARepeat: false, keyCode: 53) else { throw CocoaError(.coderInvalidValue) }
        NSApp.postEvent(escape, atStart: false)
        try await wait { model.agenda == nil }
        try await finish()
        try require(window.isVisible, "Esc 收起详情时关闭了弹窗")
        try click(13)
        try await finish()
        model.moveMonth(1)
        try await finish()
        try require(model.agenda?.date == model.engine.date(2026, 10, 13), "月份导航丢失展开状态")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("agenda.json"))
    }
}
#endif
