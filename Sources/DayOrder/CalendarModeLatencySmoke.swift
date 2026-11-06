#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarModeLatencySmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "DayOrder.ModeLatency", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !(await condition()) {
                try require(Date() < deadline, "切档性能专项未在期限内就绪")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func advance() throws -> Double {
            guard let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarEventModeButton }).first else {
                throw CocoaError(.coderInvalidValue)
            }
            // performClick 含平台按钮高亮等待；启动测量通过同一生产 action，排除这段合成输入延迟。
            let start = ProcessInfo.processInfo.systemUptime
            try require(button.sendAction(button.action, to: button.target), "日程按钮未执行生产动作")
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        func finish() {
            presentation.sampleGeometry(deltaTime: 1)
            presentation.finishGeometrySampling()
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
            model.events.choose(.hidden)
            model.today = today
            model.select(selection)
            defaults.set(appearance, forKey: "appearance")
        }
        var report: [[String: Any]] = []
        do {
            for month in [2, 8, 11] {
                defaults.set(month == 8 ? "dark" : "light", forKey: "appearance")
                model.events.choose(.hidden)
                if presentation.isTransitioning {
                    try await wait { presentation.isPreparedForSampling }
                    finish()
                }
                model.today = model.engine.date(2026, month, 5)
                model.select(model.today)
                var local = Calendar(identifier: .gregorian)
                local.timeZone = .current
                let start = local.date(from: DateComponents(year: 2026, month: month, day: 5, hour: 10))!
                let values = [CalendarEvent(id: "latency-span", title: "跨周项目讨论", start: start,
                    end: start.addingTimeInterval(9 * 86400), allDay: false,
                    color: .init(red: 0.2, green: 0.45, blue: 0.95))]
                await source.configure(access: .fullAccess, values: values)
                try await Task.sleep(for: .milliseconds(120))
                try await wait { !model.events.loading && model.calendarSnappedMonth == model.month }
                await source.holdRead()
                let before = presentation.eventCaptureCounters
                let preparations = presentation.eventPreparationCount
                let synchronousMS = try advance()
                try await wait {
                    let held = await source.hasHeldRead
                    return held && presentation.isPreparedForSampling
                }
                let captured = presentation.eventCaptureCounters
                try require(captured["fullBitmaps"] == before["fullBitmaps"],
                            "日程切档仍额外采集整区位图，没有复用周行底图")
                let weeks = model.calendarTimeline(firstWeekday: 1).weekRows(inMonth: model.month)!.count
                try require(captured["snapshots"]! - before["snapshots"]! == 2 && captured["pdfs"] == before["pdfs"],
                            "日程切档仍重复采集端点或生成整页 PDF")
                let rows = captured["rows"]! - before["rows"]!
                try require(rows >= Double(weeks * 2) && rows <= Double((weeks + 1) * 2),
                            "日期底图未按周批量采样：\(rows)")
                let snapshotMS = (captured["milliseconds"]! - before["milliseconds"]!) / 2
                presentation.sampleGeometry(deltaTime: 0.06)
                presentation.transitionView?.display()
                let card = presentation.movingCardFrame
                let velocity = presentation.movingCardVelocity
                let elapsed = presentation.motionSeconds
                let refreshes = presentation.eventMarkerRefreshCount
                let markerMS = presentation.eventMarkerRefreshMilliseconds
                let refreshStart = ProcessInfo.processInfo.systemUptime
                await source.finishRead(values)
                try await wait { !model.events.loading }
                try require(presentation.eventPreparationCount == preparations + 1 &&
                            presentation.eventCaptureCounters == captured,
                            "事件返回后重新准备整页动画或重拍底图")
                try await wait { presentation.eventMarkerRefreshCount > refreshes }
                let refreshMS = (ProcessInfo.processInfo.systemUptime - refreshStart) * 1000
                presentation.sampleGeometry(deltaTime: 0)
                presentation.transitionView?.display()
                try require(presentation.movingCardFrame == card && presentation.movingCardVelocity == velocity &&
                            presentation.motionSeconds == elapsed, "事件返回重置了容器位置、速度或时钟")
                let markers = presentation.eventMarkerSample ?? [:]
                try require(markers.keys.filter { $0.contains(":latency-span:") }.count >= 9,
                            "异步返回的跨日事件未进入真实标记绘制")
                presentation.sampleGeometry(deltaTime: 0.04)
                presentation.transitionView?.display()
                try require((presentation.eventMarkerSample ?? [:]).values.contains { $0["opacity"]! > 0.05 && $0["opacity"]! < 0.99 },
                            "异步日程缺少真实展开中间态")
                report.append(["month": month, "synchronousMS": synchronousMS, "snapshotMS": snapshotMS,
                               "fullBitmapCaptures": captured["fullBitmaps"]! - before["fullBitmaps"]!,
                               "rowCaptures": rows, "markerRefreshWallMS": refreshMS,
                               "markerRefreshMS": presentation.eventMarkerRefreshMilliseconds - markerMS,
                               "preparationMS": presentation.preparationMilliseconds,
                               "preparationPhases": presentation.preparationPhases])
                if month == 11 {
                    // 模式专用快照不提前生成年概览画布；真正进入年概览时再采集。
                    model.openYearOverview()
                    try await wait { presentation.isPreparedForSampling }
                    presentation.sampleGeometry(deltaTime: 0.06)
                    presentation.transitionView?.display()
                    try require(presentation.canvasSample != nil && presentation.matchedDayCount >= 28,
                                "切档途中进入年概览丢失日期缩放画布")
                    finish()
                    model.dismissYearLevel()
                    try await wait { presentation.isPreparedForSampling }
                    finish()
                } else { finish() }
            }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("mode-latency.json"))
            let sync = report.map { $0["synchronousMS"] as! Double }.sorted()
            let snapshots = report.map { $0["snapshotMS"] as! Double }.sorted()
            try require(sync[1] < 20 && snapshots[1] < 20,
                        "切档同步准备或快照仍超出 20 ms 预算：\(sync)，\(snapshots)")
        } catch {
            await source.finishRead([])
            throw error
        }
    }
}
#endif
