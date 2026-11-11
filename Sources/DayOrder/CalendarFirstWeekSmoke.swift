#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarFirstWeekSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL,
                       save: (NSView, String) throws -> Void) async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "DayOrder.FirstWeek", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func finish() async throws {
            try await Task.sleep(for: .milliseconds(100))
            let deadline = Date().addingTimeInterval(5)
            while model.events.loading || presentation.isTransitioning {
                try require(Date() < deadline, "首周布局未及时就绪")
                if presentation.isPreparedForSampling {
                    presentation.sampleGeometry(deltaTime: 1)
                    presentation.finishGeometrySampling()
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            presentation.view.layoutSubtreeIfNeeded()
            presentation.view.display()
        }
        let selection = model.selection
        let weekday = defaults.object(forKey: "firstWeekday")
        let appearance = defaults.object(forKey: "appearance")
        let clock = presentation.controlsAnimationClock
        presentation.controlsAnimationClock = true
        defer {
            presentation.cancelTransition()
            presentation.controlsAnimationClock = clock
            model.closeAgenda()
            model.events.choose(.hidden)
            defaults.set(weekday, forKey: "firstWeekday")
            defaults.set(appearance, forKey: "appearance")
            model.select(selection)
        }
        var report: [[String: Any]] = []
        for (year, month, firstWeekday, count) in [(2026, 2, 1, 4), (2026, 9, 1, 5), (2026, 8, 1, 6),
                                                  (2021, 2, 2, 4), (2026, 9, 2, 5), (2026, 3, 2, 6)] {
            defaults.set(firstWeekday, forKey: "firstWeekday")
            let date = model.engine.date(year, month, 1)
            let values = (-7..<38).flatMap { offset in
                (0..<2).map { lane in
                    let start = model.engine.addingDays(offset, to: date).addingTimeInterval(Double(9 + lane) * 3600)
                    return CalendarEvent(id: "first-week-\(offset)-\(lane)", title: "日程 \(lane + 1)",
                        start: start, end: start.addingTimeInterval(1800), allDay: false,
                        color: .init(red: 0.3, green: 0.45, blue: 0.95), calendarTitle: "测试日历")
                }
            }
            await source.configure(access: .fullAccess, values: values)
            model.select(date)
            for mode in [CalendarEventDisplay.hidden, .detailed, .compact, .dots] {
                model.events.choose(mode)
                for style in ["light", "dark"] {
                    defaults.set(style, forKey: "appearance")
                    try await finish()
                    guard let table = descendants(presentation.host.view).compactMap({ $0 as? NSTableView })
                        .first(where: { $0.identifier?.rawValue == "calendarTimeline" }),
                          let scroll = table.enclosingScrollView else { throw CocoaError(.coderInvalidValue) }
                    let timeline = model.calendarTimeline(firstWeekday: firstWeekday)
                    let rows = timeline.weekRows(inMonth: model.engine.monthStart(date))!
                    try require(rows.count == count, "首周验证月份的周数错误")
                    let top = table.rect(ofRow: rows.lowerBound).minY
                    let bottom = table.rect(ofRow: rows.upperBound - 1).maxY
                    try require(abs(bottom - top - mode.viewportHeight) < 0.01, "首周调整改变整月高度")
                    try require(abs(table.visibleRect.minY - top) < 0.5, "首周没有对齐卡片顶部")
                    guard let week = table.view(atColumn: 0, row: rows.lowerBound, makeIfNecessary: true) as? CalendarWeekView,
                          let button = week.subviews.compactMap({ $0 as? CalendarDayButton }).first(where: { $0.date == date })
                    else { throw CocoaError(.coderInvalidValue) }
                    let selected = scroll.convert(button.focusRingMaskBounds, from: button)
                    let inset = selected.minY - scroll.bounds.minY
                    // 周内几何精确检查；原生表格累计坐标和滚动视口各自对齐屏幕像素。
                    let pixel = 1 / (scroll.window?.backingScaleFactor ?? 2)
                    try require(abs(button.frame.minY + button.focusRingMaskBounds.minY - 6.5) < 0.01
                                && abs(inset - 6.5) <= pixel + 0.001,
                                "首周选中灰底顶部间距应为 6.5 pt，实际 \(inset)，\(year)-\(month)，\(mode)")
                    for row in rows {
                        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? CalendarWeekView
                        else { throw CocoaError(.coderInvalidValue) }
                        view.layoutSubtreeIfNeeded()
                        for day in view.subviews.compactMap({ $0 as? CalendarDayButton }) {
                            let last = max(day.focusRingMaskBounds.maxY, day.eventMarkers.map { $0.style.frame.maxY }.max() ?? 0)
                            try require(day.frame.minY >= 0 && day.frame.minY + last <= view.bounds.height - 0.5,
                                        "日期或日程标记越过周分隔线：第 \(row - rows.lowerBound + 1) 周")
                        }
                    }
                    if mode != .hidden {
                        let originalTop = button.frame.minY
                        try require(button.accessibilityPerformPress(), "首周日期无法展开")
                        try await finish()
                        let agenda = week.agendaView
                        let contentBottom = week.subviews.compactMap({ $0 as? CalendarDayButton }).map { day in
                            day.frame.minY + max(day.focusRingMaskBounds.maxY, day.eventMarkers.map { $0.style.frame.maxY }.max() ?? 0)
                        }.max()!
                        try require(!agenda.isHidden && abs(button.frame.minY - originalTop) < 0.01,
                                    "首周展开改变日期位置")
                        try require(abs(agenda.frame.minY + 4 - contentBottom - 8) < 0.01,
                                    "首周日程顶部间距不是 8 pt")
                        let backgroundBottom = agenda.frame.maxY - CalendarDayAgendaLayout.backgroundBottomInset
                        try require(abs(week.bounds.height - 0.5 - backgroundBottom - 6) < 0.01,
                                    "首周日程底部间距不是 6 pt")
                        if count == 6 && firstWeekday == 1 {
                            try save(presentation.view, "first-week-\(mode)-\(style)-expanded")
                        }
                        model.closeAgenda()
                        try await finish()
                    }
                    report.append(["year": year, "month": month, "firstWeekday": firstWeekday,
                                   "weeks": count, "mode": "\(mode)", "appearance": style, "topInset": inset,
                                   "monthHeight": bottom - top])
                }
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("first-week-geometry.json"))
    }
}
#endif
