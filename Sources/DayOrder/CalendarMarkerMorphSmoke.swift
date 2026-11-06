#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarMarkerMorphSmoke {
    static func verify(model: CalendarModel, presentation: CalendarPresentationController,
                       source: SmokeCalendarSource, defaults: UserDefaults, directory: URL,
                       save: (NSView, String) throws -> Void) async throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "DayOrder.MarkerMorph", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !condition() {
                try require(Date() < deadline, "日程形变未在期限内就绪：模式=\(model.events.mode)，过渡=\(presentation.isTransitioning)，采样=\(presentation.isPreparedForSampling)，读取=\(model.events.loading)，窗口=\(presentation.view.window?.isVisible == true)")
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func click() throws {
            guard let button = descendants(presentation.host.view).compactMap({ $0 as? CalendarEventModeButton }).first else {
                throw CocoaError(.coderInvalidValue)
            }
            button.performClick(nil)
        }
        func prepared() async throws {
            try await wait { presentation.isPreparedForSampling && !model.events.loading }
        }
        func draw(_ delta: Double) throws -> [String: [String: Double]] {
            presentation.sampleGeometry(deltaTime: delta)
            presentation.transitionView?.display()
            guard let sample = presentation.eventMarkerSample else { throw CocoaError(.coderInvalidValue) }
            return sample
        }
        func primary(_ sample: [String: [String: Double]]) throws -> [String: Double] {
            guard let key = sample.keys.sorted().first(where: { $0.contains(":morph-primary:") }),
                  let value = sample[key] else {
                throw NSError(domain: "DayOrder.MarkerMorph", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "主日程形变状态丢失"])
            }
            return value
        }
        func finish() {
            if presentation.isPreparedForSampling {
                presentation.sampleGeometry(deltaTime: 1)
                presentation.finishGeometrySampling()
            }
        }
        func verifyPixels(_ value: [String: Double]) throws {
            guard let view = presentation.transitionView else { throw CocoaError(.coderInvalidValue) }
            let rect = CGRect(x: value["worldX"]!, y: value["worldY"]!,
                              width: value["width"]!, height: value["height"]!)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.coderInvalidValue) }
            view.cacheDisplay(in: rect, to: bitmap)
            var colored = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.blueComponent > max(color.redComponent, color.greenComponent) + 0.025 {
                        colored += 1
                    }
                }
            }
            try require(colored > 0, "标记有几何采样却没有实际绘制蓝色像素")
        }
        let original = model.selection
        let today = model.today
        let appearance = defaults.object(forKey: "appearance")
        presentation.controlsAnimationClock = true
        presentation.reduceMotionOverride = false
        defer {
            presentation.cancelTransition()
            presentation.controlsAnimationClock = false
            presentation.reduceMotionOverride = nil
            model.events.choose(.hidden)
            defaults.set(appearance, forKey: "appearance")
            model.today = today
            model.select(original)
        }
        var report: [[String: Any]] = []
        for month in [11, 8] {
            let dark = month == 8
            defaults.set(dark ? "dark" : "light", forKey: "appearance")
            model.events.choose(.hidden)
            finish()
            model.today = model.engine.date(2026, month, 5)
            model.select(model.today)
            var local = Calendar(identifier: .gregorian)
            local.timeZone = .current
            let start = local.date(from: DateComponents(year: 2026, month: month, day: 5, hour: 10))!
            let values = [
                CalendarEvent(id: "morph-primary", title: "产品设计讨论", start: start,
                    end: start.addingTimeInterval(72 * 3600), allDay: false,
                    color: .init(red: 0.15, green: 0.4, blue: 0.95)),
                CalendarEvent(id: "repeat", title: "重复实例一", start: start.addingTimeInterval(4000),
                    end: start.addingTimeInterval(5000), allDay: false,
                    color: .init(red: 0.8, green: 0.2, blue: 0.5)),
                CalendarEvent(id: "repeat", title: "重复实例二", start: start.addingTimeInterval(8000),
                    end: start.addingTimeInterval(9000), allDay: false,
                    color: .init(red: 0.2, green: 0.7, blue: 0.4))
            ]
            await source.configure(access: .fullAccess, values: values)
            try await Task.sleep(for: .milliseconds(100))
            try await wait { model.calendarScrollAnimationSelection == nil && model.calendarSnappedMonth == model.month }
            for mode in [CalendarEventDisplay.detailed, .compact, .dots, .hidden] {
                let counts = await source.counters()
                try click()
                try await prepared()
                var frames: [[String: Double]] = []
                for index in 0...72 {
                    let sample = try draw(index == 0 ? 0 : 1.0 / 120)
                    let value = try primary(sample)
                    frames.append(value)
                    if [0, 6, 12, 24, 72].contains(index) {
                        try save(presentation.view, "marker-\(month)-\(mode.rawValue)-\(index)")
                    }
                    if index == 12 && mode != .hidden { try verifyPixels(value) }
                    if mode == .compact {
                        try require(sample.filter { $0.key.contains(":repeat:") && $0.value["detail"]! > 0.000001 }
                            .allSatisfy { $0.value["summary"] == 1 }, "收起时更多日程计数跳变成事件名")
                    }
                    if mode == .compact || mode == .dots {
                        try require(sample.keys.filter { $0.contains(":repeat:") }.count == 2,
                                    "同一事件标识的不同重复实例被合并：月份=\(month)，模式=\(mode)，帧=\(index)，标记=\(sample.keys.sorted())")
                    }
                }
                switch mode {
                case .detailed:
                    try require(frames.contains { $0["height"]! > 4 && $0["height"]! < 11 && $0["opacity"]! > 0.1 },
                                "隐藏后没有从圆点连续展开为胶囊")
                case .compact:
                    try require(frames.contains { $0["height"]! > 3 && $0["height"]! < 11 && $0["detail"]! > 0 && $0["detail"]! < 1 },
                                "胶囊未连续压扁成横线，或文字没有渐隐")
                case .dots:
                    try require(frames.contains { $0["width"]! > 5 && $0["width"]! < frames.first!["width"]! - 2 },
                                "横线未连续缩短成圆点")
                case .hidden:
                    try require(frames.contains { $0["opacity"]! > 0.1 && $0["opacity"]! < 0.9 && abs($0["width"]! - 3.5) < 0.1 },
                                "圆点未逐帧淡出")
                    try require(await source.counters() == counts && model.events.days.isEmpty,
                                "离场动画重新检测权限或保留了事件库")
                }
                try require(frames.last!["error"]! < 0.02, "日程形变未收敛到静态末态")
                try require(descendants(presentation.host.view).compactMap { $0 as? CalendarDayButton }
                    .allSatisfy { !$0.snapshotHidesEventMarkers }, "截图采集没有恢复真实日期标记")
                report.append(["month": month, "mode": mode.rawValue, "frames": frames])
                finish()
                try save(presentation.view, "marker-\(month)-\(mode.rawValue)-live")
            }
            // 受控时钟比较重定向前后同一实际绘制状态，排除准备耗时。
            try click()
            try await prepared()
            _ = try draw(0.06)
            for _ in 0..<8 {
                let before = try draw(0)
                try click()
                try await prepared()
                let after = try draw(0)
                for (key, value) in before {
                    guard let next = after[key] else { throw CocoaError(.coderInvalidValue) }
                    for field in ["x", "y", "width", "height", "opacity", "detail", "fill",
                                  "velocityX", "velocityY", "velocityWidth", "velocityHeight",
                                  "velocityOpacity", "velocityDetail", "velocityFill"] {
                        try require(abs(value[field]! - next[field]!) < 0.0001,
                                    "快速切档重置了标记的 \(field)")
                    }
                }
                _ = try draw(0.025)
            }
            finish()
            presentation.reduceMotionOverride = true
            try click()
            try await prepared()
            presentation.sampleGeometry(deltaTime: 0.06)
            presentation.transitionView?.display()
            try require(presentation.eventMarkerSample == nil, "减少动态效果仍进行标记形变")
            finish()
            presentation.reduceMotionOverride = false
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("marker-morph.json"))
    }
}
#endif
