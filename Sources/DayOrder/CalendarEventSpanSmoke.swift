#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarEventSpanSmoke {
    static func verify(buttons: [CalendarDayButton], mode: CalendarEventDisplay,
                       root: NSView, snapshot: URL) throws -> Int {
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "DayOrder.EventSpan", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        for button in buttons {
            for marker in button.eventMarkers {
                let clipped = button.bounds.intersection(marker.style.frame)
                try require(!clipped.isNull && clipped.minY >= 45 && button.bounds.contains(clipped),
                            "日程可见部分覆盖农历或越过日期格")
            }
        }
        guard mode == .detailed || mode == .compact else { return 0 }
        guard let rendered = NSBitmapImageRep(data: try Data(contentsOf: snapshot)) else { throw CocoaError(.coderInvalidValue) }
        let spanning = buttons.filter { $0.events.contains { $0.id == "retreat" } }
        try require(spanning.count >= 9, "跨周日程未覆盖完整九天")
        let weeks = Dictionary(grouping: spanning) { ObjectIdentifier($0.superview!) }
        var seams = 0
        var background: NSColor?
        for group in weeks.values {
            let ordered = group.sorted { $0.frame.minX < $1.frame.minX }
            let week = ordered[0].superview!
            var previous: CGRect?
            for button in ordered {
                guard let marker = button.eventMarkers.first(where: { $0.id.event == "retreat" }) else {
                    throw NSError(domain: "DayOrder.EventSpan", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "重叠排布或溢出计数切断了跨日横条"])
                }
                let rect = week.convert(marker.style.frame, from: button)
                try require(rect.width > button.bounds.width, "跨日事件仍被拆成单日标签")
                if let previous {
                    try require(abs(rect.minX - previous.minX) < 0.01 && abs(rect.minY - previous.minY) < 0.01
                                && abs(rect.width - previous.width) < 0.01, "同一横条在相邻日期错行或断开")
                    // 直接采集日期列接缝，不能只用布局矩形证明横条已绘出。
                    let probe = CGRect(x: button.frame.minX - 0.5, y: rect.midY - 0.5, width: 1, height: 1)
                    guard let bitmap = week.bitmapImageRepForCachingDisplay(in: probe) else { throw CocoaError(.coderInvalidValue) }
                    week.cacheDisplay(in: probe, to: bitmap)
                    for y in 0..<bitmap.pixelsHigh {
                        for x in 0..<bitmap.pixelsWide {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                                throw CocoaError(.coderInvalidValue)
                            }
                            try require(color.blueComponent > max(color.redComponent, color.greenComponent) + 0.025,
                                        "跨日横条在日期列接缝处缺少蓝色像素")
                        }
                    }
                    seams += 1
                }
                previous = rect
            }
            if mode == .detailed, let last = ordered.last,
               let marker = last.eventMarkers.first(where: { $0.id.event == "retreat" }) {
                let rect = week.convert(marker.style.frame, from: last)
                // 检查完整面板快照；局部重绘的裁切可能掩盖兄弟视图向外叠绘。
                let point = root.convert(CGPoint(x: last.frame.maxX - 6, y: rect.midY), from: week)
                let x = Int((point.x - root.bounds.minX) * CGFloat(rendered.pixelsWide) / root.bounds.width)
                let top = root.isFlipped ? point.y - root.bounds.minY : root.bounds.maxY - point.y
                let y = Int(top * CGFloat(rendered.pixelsHigh) / root.bounds.height)
                guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw CocoaError(.coderInvalidValue) }
                try require(color.blueComponent > max(color.redComponent, color.greenComponent) + 0.025,
                            "整周底色采样未落在跨日横条内")
                if let background {
                    try require(abs(color.redComponent - background.redComponent) < 0.02
                                && abs(color.greenComponent - background.greenComponent) < 0.02
                                && abs(color.blueComponent - background.blueComponent) < 0.02,
                                "同一跨日日程的长短周段底色不一致，背景可能重复叠绘")
                }
                background = color
            }
        }
        try require(seams >= 7, "跨周横条接缝未被实际采样")
        return seams
    }
}
#endif
