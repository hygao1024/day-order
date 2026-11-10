#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarAgendaPerformanceSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, directory: URL) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DayOrder.AgendaPerformance", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.events.loading || (presentation.isTransitioning && !presentation.isPreparedForSampling) {
                try require(Date() < deadline, "滚动性能前置状态未就绪")
                try await Task.sleep(for: .milliseconds(10))
            }
            if presentation.isPreparedForSampling {
                presentation.sampleGeometry(deltaTime: 1)
                presentation.finishGeometrySampling()
            }
            presentation.view.layoutSubtreeIfNeeded()
            presentation.view.display()
            try await Task.sleep(for: .milliseconds(50))
        }
        let date = model.engine.date(2026, 12, 7)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let start = local.date(from: DateComponents(year: 2026, month: 12, day: 7, hour: 10))!
        presentation.controlsAnimationClock = true
        defer { presentation.cancelTransition(); presentation.controlsAnimationClock = false; model.closeAgenda() }
        var report: [[String: Any]] = []
        for count in [12, 200] {
            let values = (0..<count).map { index in
                CalendarEvent(id: "perf-\(index)", title: "产品方案评审与后续任务安排 \(index)",
                    start: start, end: start.addingTimeInterval(3600), allDay: false,
                    color: .init(red: 0.3, green: 0.4, blue: 0.9), calendarTitle: "性能样例")
            }
            await source.configure(access: .fullAccess, values: values)
            model.events.choose(.detailed)
            for expanded in [false, true] {
                model.select(date)
                try await settle()
                guard let table = descendants(presentation.host.view).compactMap({ $0 as? NSTableView })
                    .first(where: { $0.identifier?.rawValue == "calendarTimeline" }),
                      let coordinator = table.delegate as? CalendarTimelineView.Coordinator,
                      let scroll = table.enclosingScrollView as? CalendarTimelineScrollView else { throw CocoaError(.coderInvalidValue) }
                if expanded {
                    guard let button = descendants(table).compactMap({ $0 as? CalendarDayButton })
                        .first(where: { $0.date == date && !$0.visibleRect.isEmpty }), button.accessibilityPerformPress() else { throw CocoaError(.coderInvalidValue) }
                    try await settle()
                }
                scroll.onActivity?()
                let origin = scroll.contentView.bounds.minY
                let measurements = CalendarDayAgendaLayout.measurements
                let configurations = coordinator.weekConfigurations
                let heights = coordinator.heightQueries
                let preparations = presentation.eventPreparationCount
                var samples: [Double] = []
                for index in 0..<120 {
                    let step = index < 60 ? index + 1 : 119 - index
                    let began = ProcessInfo.processInfo.systemUptime
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: origin + CGFloat(step) * 24))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    table.layoutSubtreeIfNeeded()
                    presentation.view.display()
                    samples.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
                    try await Task.sleep(for: .milliseconds(8))
                }
                try await settle()
                let sorted = samples.sorted()
                report.append(["events": count, "expanded": expanded, "medianMS": sorted[60], "p95MS": sorted[114],
                    "maxMS": sorted.last!, "measurements": CalendarDayAgendaLayout.measurements - measurements,
                    "weekConfigurations": coordinator.weekConfigurations - configurations,
                    "heightQueries": coordinator.heightQueries - heights,
                    "preparations": presentation.eventPreparationCount - preparations])
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("agenda-performance.json"))
                try require(model.selection == date && (model.agenda != nil) == expanded, "滚动改变了展开或选择状态")
                if expanded {
                    try require(presentation.eventPreparationCount == preparations, "滚动触发了无关或离屏日程动画")
                    guard let agenda = descendants(table).compactMap({ $0 as? CalendarDayAgendaView })
                        .first(where: { !$0.isHidden }) else { throw CocoaError(.coderInvalidValue) }
                    try require(agenda.itemCount == count && agenda.scroll.documentView!.subviews.count < 12,
                                "大量日程仍一次创建全部行或丢失数据")
                    let last = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -100000, wheel2: 0, wheel3: 0)!
                    agenda.scroll.scrollWheel(with: NSEvent(cgEvent: last)!)
                    agenda.layoutSubtreeIfNeeded()
                    try require(descendants(agenda).compactMap { $0 as? NSTextField }
                        .contains { $0.stringValue == model.events.days[date]?.last?.title }, "最后一项日程不可达")
                    let cached = model.agendaLayout
                    let measured = CalendarDayAgendaLayout.measurements
                    for _ in 0..<10 { _ = model.agendaLayout }
                    try require(CalendarDayAgendaLayout.measurements == measured, "未变化的日程重复测量")
                    let other = CalendarEvent(id: "other", title: "其他日期更新", start: start.addingTimeInterval(86400),
                        end: start.addingTimeInterval(90000), allDay: false, color: values[0].color)
                    await source.configure(access: .fullAccess, values: values + [other])
                    model.events.update(month: model.month, engine: model.engine)
                    try await settle()
                    try require(presentation.eventPreparationCount == preparations && model.agendaLayout === cached,
                                "其他日期更新重做了当日布局或动画")
                    var changed = values
                    changed[0] = CalendarEvent(id: values[0].id, title: "已更新的当天日程", start: start,
                        end: start.addingTimeInterval(3600), allDay: false, color: values[0].color)
                    await source.configure(access: .fullAccess, values: changed)
                    model.events.update(month: model.month, engine: model.engine)
                    try await settle()
                    try require(presentation.eventPreparationCount > preparations && model.agendaLayout !== cached
                                && model.agendaLayout?.events.contains(where: { $0.id == changed[0].id && $0.title == changed[0].title }) == true,
                                "布局缓存阻止了当天日程更新")
                }
            }
        }
    }
}
#endif
