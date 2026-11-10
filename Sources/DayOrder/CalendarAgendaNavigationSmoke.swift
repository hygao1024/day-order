#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarAgendaNavigationSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, directory: URL,
                       close: () -> Void, reopen: () -> Void) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DayOrder.AgendaNavigation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func wait(line: Int = #line, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                try require(Date() < deadline, "保留日程的导航未及时完成：检查行=\(line)，月份=\(model.month)，选择=\(model.selection)，读取=\(model.events.loading)，过渡=\(presentation.isTransitioning)")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func settle() async throws {
            await Task.yield()
            try await wait { !presentation.isTransitioning && !model.events.loading }
            presentation.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            try await wait { !presentation.isTransitioning && !model.events.loading }
        }
        func day(_ date: Date) throws -> CalendarDayButton {
            guard let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayButton })
                .first(where: { $0.date == date && !$0.visibleRect.isEmpty }) else {
                throw NSError(domain: "DayOrder.AgendaNavigation", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "目标日期按钮不可见：\(date)，当前月份：\(model.month)"])
            }
            return button
        }
        func pressToday() throws {
            func find(_ element: AnyObject) -> AnyObject? {
                if element.accessibilityRole?() == .button, element.accessibilityLabel?() == "今天" { return element }
                for child in element.accessibilityChildren?() ?? [] {
                    if let found = find(child as AnyObject) { return found }
                }
                return nil
            }
            guard let button = find(presentation.host.view), button.accessibilityPerformPress?() == true else {
                throw CocoaError(.coderInvalidValue)
            }
        }
        let originalToday = model.today
        defer { model.closeAgenda(); model.today = originalToday }
        try require(!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "导航连续性检查需要关闭系统减少动态效果")
        model.events.choose(.detailed)
        var reports: [[String: Any]] = []
        for (month, number, todayNumber, distance, lateUpdate) in [
            (1, 1, 1, 1, false), (10, 6, 6, 1, false), (10, 13, 6, 1, false),
            (11, 1, 10, 4, false), (11, 1, 10, 4, true)
        ] {
            model.closeAgenda()
            let date = model.engine.date(2026, month, number)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let start = calendar.date(from: DateComponents(year: 2026, month: month, day: number, hour: 10))!
            var values = [CalendarEvent(id: "retained", title: "导航后保留的日程",
                start: start, end: start.addingTimeInterval(3600), allDay: false,
                color: .init(red: 0.3, green: 0.45, blue: 0.95), calendarTitle: "工作日历")]
            await source.configure(access: .fullAccess, values: values)
            model.today = model.engine.date(2026, month, todayNumber)
            model.select(date)
            try await settle()
            try await wait { descendants(presentation.host.view).compactMap { $0 as? CalendarDayButton }
                .contains { $0.date == date && !$0.visibleRect.isEmpty } }
            try require(try day(date).accessibilityPerformPress(), "未展开测试日期")
            try await settle()
            let expanded = model.agenda
            try require(expanded?.date == date, "测试日期未保持展开")
            let table = try day(date).enclosingScrollView!.documentView as! NSTableView
            let scroll = table.enclosingScrollView as! CalendarTimelineScrollView
            let coordinator = table.delegate as! CalendarTimelineView.Coordinator
            let timeline = model.calendarTimeline(firstWeekday: 1)
            let nextMonth = model.engine.addingMonths(distance, to: date)
            let row = timeline.weekRows(inMonth: model.engine.monthStart(nextMonth))!.lowerBound
            scroll.onActivity?()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY + 30))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            if distance > 1 {
                try require(model.events.days[date] == nil, "远月前置场景未移出原日期的数据范围")
            }
            let origin = scroll.contentView.bounds.minY
            let targetRow = timeline.weekRows(inMonth: model.engine.monthStart(model.today))!.lowerBound
            let target = table.rect(ofRow: targetRow).minY
            try require(origin - target > 300, "未滚动到其他月份")
            let preparations = presentation.eventPreparationCount
            try pressToday()
            try require(model.agenda == expanded, "返回今天收起了原日程")
            try await wait { coordinator.hasActiveSnapDriver }
            var positions: [CGFloat] = []
            var injected = false
            var receivedWhileNavigating = false
            let deadline = Date().addingTimeInterval(5)
            while coordinator.hasActiveSnapDriver || model.calendarScrollAnimationSelection != nil {
                try require(Date() < deadline, "返回今天的滚动驱动未停止")
                let position = scroll.contentView.bounds.minY
                positions.append(position)
                if lateUpdate && !injected && position < target + 80 && position > target + 3 {
                    let visibleAgenda = descendants(table).compactMap { $0 as? CalendarDayAgendaView }
                        .contains { !$0.isHidden && !$0.visibleRect.isEmpty }
                    try require(visibleAgenda, "迟到更新未覆盖可见详情")
                    injected = true
                    values.append(CalendarEvent(id: "late", title: "返回途中新增日程", start: start.addingTimeInterval(7200),
                        end: start.addingTimeInterval(10800), allDay: false, color: values[0].color))
                    await source.configure(access: .fullAccess, values: values)
                    model.events.update(month: model.month, engine: model.engine)
                }
                if injected && model.events.days[date]?.count == 2 && coordinator.hasActiveSnapDriver {
                    receivedWhileNavigating = true
                }
                try require(model.agenda == expanded && !presentation.isTransitioning,
                            "返回今天丢失日程或启动了淡入过渡")
                try await Task.sleep(for: .milliseconds(10))
            }
            try await settle()
            try require(!lateUpdate || receivedWhileNavigating, "未在导航期间接收可见日程更新")
            try require(positions.contains { $0 < origin - 2 && $0 > target + 2 }, "返回今天缺少中间滚动位置")
            try require(abs(scroll.contentView.bounds.minY - target) < 1 && model.selection == model.today,
                        "返回今天没有到达目标月份或日期")
            try require(model.agenda == expanded && presentation.eventPreparationCount == preparations,
                        "返回今天改变了展开状态或重新准备了详情动画")
            let agenda = descendants(table).compactMap { $0 as? CalendarDayAgendaView }.first { !$0.isHidden }
            try require(agenda?.heading.stringValue.contains("\(number)日 · \(values.count)项日程") == true,
                        "返回后原日期详情未显示")
            try require(agenda.map { descendants($0).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "导航后保留的日程" } } == true, "返回后原日程内容丢失")
            reports.append(["month": month, "day": number, "distance": distance, "lateUpdate": lateUpdate, "positions": positions])
            if date != model.today {
                try require(try day(model.today).accessibilityPerformPress(), "今天日期按钮未执行")
                try await settle()
                try require(model.agenda?.date == model.today, "选中日期与展开日期不同时误收起了其他日程")
            }
            close()
            try require(model.agenda == nil, "关闭弹窗未清除展开状态")
            reopen()
            try await settle()
            try require(model.agenda == nil && !descendants(presentation.host.view)
                .compactMap { $0 as? CalendarDayAgendaView }.contains { !$0.isHidden }, "重新打开弹窗恢复了旧详情")
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("agenda-navigation.json"))
    }
}
#endif
