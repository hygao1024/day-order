#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarAgendaWheelSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, directory: URL) async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "DayOrder.AgendaWheel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(80))
            let deadline = Date().addingTimeInterval(5)
            while model.events.loading || presentation.isTransitioning {
                try require(Date() < deadline, "滚轮测试前置界面未就绪")
                try await Task.sleep(for: .milliseconds(10))
            }
            presentation.view.layoutSubtreeIfNeeded()
        }
        func button(_ number: Int) throws -> CalendarDayButton {
            guard let view = descendants(presentation.host.view).compactMap({ $0 as? CalendarDayButton })
                .first(where: { $0.date == model.engine.date(2026, 11, number) && !$0.visibleRect.isEmpty }) else {
                throw CocoaError(.coderInvalidValue)
            }
            return view
        }
        let date = model.engine.date(2026, 11, 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10))!
        defer { model.closeAgenda() }
        var report: [[String: Any]] = []
        for count in [0, 1, 12, 1] {
            model.closeAgenda()
            try await settle()
            let values = (0..<count).map { index in
                CalendarEvent(id: "wheel-\(index)", title: "日程滚轮测试 \(index)",
                    start: start, end: start.addingTimeInterval(3600), allDay: false,
                    color: .init(red: 0.8, green: 0.4, blue: 0.1))
            }
            await source.configure(access: .fullAccess, values: values)
            model.select(date)
            model.events.choose(.detailed)
            try await settle()
            try require(try button(1).accessibilityPerformPress(), "未展开日程")
            try await settle()
            let expanded = model.agenda
            let outer = try button(1).enclosingScrollView as! CalendarTimelineScrollView
            let table = outer.documentView as! NSTableView
            let coordinator = table.delegate as! CalendarTimelineView.Coordinator
            guard let window = table.window, let root = window.contentView,
                  let agenda = descendants(table).compactMap({ $0 as? CalendarDayAgendaView }).first(where: { !$0.isHidden }) else {
                throw CocoaError(.coderInvalidValue)
            }
            let origin = outer.contentView.bounds.origin
            func send(_ point: NSPoint, precise: Bool, delta: Int64, phase: Int64) throws {
                // 从带窗口身份的事件构造滚轮，经过应用分发；不直接指定滚动视图接收者。
                let seed = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                NSApp.sendEvent(seed)
                let cg = seed.cgEvent!
                cg.type = .scrollWheel
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
                cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: delta)
                cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: delta * 12)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: precise ? phase : 0)
                let event = NSEvent(cgEvent: cg)!
                try require(event.window === window && hypot(event.locationInWindow.x - point.x, event.locationInWindow.y - point.y) < 0.5,
                            "测试滚轮的窗口或坐标错误")
                NSApp.sendEvent(event)
            }
            for precise in [false, true] {
                let areas = ["day-2", "day-9", "day-16"] + (count < 12 ? ["day-23"] : [])
                    + ["top", "padding", "body", "bottom"]
                for area in areas {
                    coordinator.beginInteraction()
                    outer.contentView.scroll(to: origin)
                    outer.reflectScrolledClipView(outer.contentView)
                    agenda.scroll.contentView.scroll(to: .zero)
                    presentation.view.layoutSubtreeIfNeeded()
                    let internalScroll = count == 12 && (area == "body" || area == "bottom")
                    if area == "bottom" {
                        let limit = max(0, agenda.scroll.documentView!.bounds.height - agenda.scroll.contentSize.height)
                        agenda.scroll.contentView.scroll(to: NSPoint(x: 0, y: limit))
                    }
                    let view: NSView
                    let local: NSPoint
                    if area.hasPrefix("day-") {
                        view = try button(Int(area.dropFirst(4))!)
                        local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
                    } else if area == "top" {
                        view = agenda
                        local = NSPoint(x: view.bounds.midX, y: 6)
                    } else if area == "padding" {
                        view = agenda
                        local = NSPoint(x: 3, y: agenda.bounds.midY)
                    } else {
                        view = agenda.scroll
                        local = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
                    }
                    let point = view.convert(local, to: nil)
                    let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
                    let before = outer.contentView.bounds.minY
                    let innerBefore = agenda.scroll.contentView.bounds.minY
                    let outerEvents = outer.wheelEvents
                    let innerEvents = agenda.scroll.wheelEvents
                    try send(point, precise: precise, delta: -5, phase: 1)
                    try await Task.sleep(for: .milliseconds(50))
                    let delta = outer.contentView.bounds.minY - before
                    let innerDelta = agenda.scroll.contentView.bounds.minY - innerBefore
                    if precise { try send(point, precise: true, delta: 0, phase: 4) }
                    report.append(["items": count, "precise": precise, "area": area,
                        "hit": hit.map { String(describing: type(of: $0)) } ?? "nil",
                        "point": NSStringFromPoint(point), "window": NSStringFromRect(window.frame),
                        "viewport": NSStringFromRect(outer.convert(outer.bounds, to: nil)),
                        "outerDelta": delta, "innerDelta": innerDelta,
                        "outerEvents": outer.wheelEvents - outerEvents, "innerEvents": agenda.scroll.wheelEvents - innerEvents])
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("agenda-wheel.json"))
                    try require(model.agenda == expanded, "滚轮改变了展开日期")
                    if internalScroll {
                        try require(abs(delta) < 0.5 && outer.wheelEvents == outerEvents,
                                    "可滚动日程列表把事件传给了外层：\(area)")
                        try require(area == "bottom" ? abs(innerDelta) < 0.5 : innerDelta > 1,
                                    "内层日程滚动或边界行为错误：\(area)")
                    } else {
                        try require(delta > 1 && outer.wheelEvents > outerEvents,
                                    "无需内层滚动时日历未移动：项数=\(count)，区域=\(area)，精确滚动=\(precise)，命中=\(String(describing: hit))")
                    }
                    // 等待原生滚动尾部和月初吸附结束，避免上一个位置的运动污染下一次分发。
                    try await Task.sleep(for: .milliseconds(550))
                }
            }
        }
    }
}

#endif
