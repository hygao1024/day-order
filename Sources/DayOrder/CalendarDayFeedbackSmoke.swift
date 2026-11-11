#if DEBUG
import AppKit
import DayOrderCore

@MainActor enum CalendarDayFeedbackSmoke {
    @MainActor private final class Probe: NSObject {
        var samples: [[String: Double]] = []
        var clicks = 0
        var timerAction: ((Timer) -> Void)?
        @objc func tick(_ timer: Timer) { timerAction?(timer) }
    }

    static func verify(engine: CalendarEngine, directory: URL,
                       save: (NSView, String) throws -> Void) async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "DayOrder.DayFeedback", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 64, height: 64),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = CalendarDayButton(frame: NSRect(x: 8, y: 8, width: 48, height: 46))
        window.contentView!.addSubview(button)
        window.orderFront(nil)
        defer { window.close() }
        let probe = Probe()
        let date = engine.date(2026, 10, 13)
        func configure(selected: Bool) {
            button.configure(day: engine.info(for: date), annotations: [], holiday: nil, isInMonth: true,
                events: [], mode: .hidden, segments: [], column: 0, overflow: 0,
                today: engine.date(2026, 10, 6), selection: selected ? date : engine.date(2026, 10, 14),
                enabled: true) { probe.clicks += 1 }
        }
        func capture(_ phase: Double) -> [String: Double] {
            let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
            button.cacheDisplay(in: button.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / button.bounds.width
            let color = bitmap.colorAt(x: Int(4 * scale), y: Int(23 * scale))!.usingColorSpace(.sRGB)!
            return ["phase": phase, "opacity": Double(button.feedbackSample),
                    "red": Double(color.redComponent), "alpha": Double(color.alphaComponent)]
        }
        for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            window.appearance = NSAppearance(named: appearance)
            button.feedbackReduceMotionOverride = false
            configure(selected: true)
            _ = capture(0)
            // 先完成窗口首次呈现，避免首帧准备占掉短按压过渡的取样区间。
            try await Task.sleep(for: .milliseconds(100))
            probe.samples.removeAll()
            let location = button.convert(NSPoint(x: 24, y: 12), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                timestamp: timestamp + 0.24, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0)!
            let began = ProcessInfo.processInfo.systemUptime
            let framesBefore = button.feedbackFrameCount
            probe.timerAction = { timer in
                probe.samples.append(capture(1))
                if ProcessInfo.processInfo.systemUptime - began >= 0.24 {
                    timer.invalidate()
                    NSApp.postEvent(up, atStart: true)
                }
            }
            let timer = Timer(timeInterval: 0.006, target: probe, selector: #selector(Probe.tick(_:)),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            NSApp.sendEvent(down)
            timer.invalidate()
            probe.timerAction = nil
            let pressed = probe.samples
            try require(pressed.contains { $0["opacity"]! > 0.061 && $0["opacity"]! < 0.089 },
                        "真实按下没有背景颜色中间态：\(appearance)，\(pressed)")
            try require(button.feedbackFrameCount > framesBefore, "原生鼠标跟踪期间未执行帧回调")
            try require(abs(pressed.last!["opacity"]! - 0.09) < 0.001, "按下颜色未收敛")
            for _ in 0..<16 {
                probe.samples.append(capture(2))
                try await Task.sleep(for: .milliseconds(12))
            }
            let released = probe.samples.filter { $0["phase"] == 2 }
            try require(released.contains { $0["opacity"]! > 0.061 && $0["opacity"]! < 0.089 }, "松开缺少颜色中间态")
            try require(abs(button.feedbackSample - 0.06) < 0.001 && !button.feedbackIsAnimating,
                        "松开没有恢复选中底色或帧驱动未停止")
            try require(Set(probe.samples.map { $0["red"]! + $0["alpha"]! }).count > 2,
                        "颜色插值没有进入实际背景像素")
            try require(probe.clicks == index + 1, "颜色动画改变了真实点击次数")
            try save(button, "day-feedback-\(index)-restored")
            button.highlight(true)
            _ = capture(3)
            try await Task.sleep(for: .milliseconds(20))
            let middle = capture(3)["opacity"]!
            try save(button, "day-feedback-\(index)-mid-press")
            button.highlight(false)
            let reversed = capture(3)["opacity"]!
            try require(abs(middle - reversed) < 0.003, "快速反向时颜色跳变")
            button.feedbackReduceMotionOverride = true
            button.highlight(true)
            _ = capture(4)
            try require(abs(button.feedbackSample - 0.09) < 0.001 && !button.feedbackIsAnimating,
                        "减少动态效果仍运行帧驱动")
            button.highlight(false)
            _ = capture(4)
            button.feedbackReduceMotionOverride = false
            configure(selected: false)
            _ = capture(5)
            button.highlight(true)
            _ = capture(5)
            try await Task.sleep(for: .milliseconds(20))
            _ = capture(5)
            button.highlight(false)
            configure(selected: true)
            let handoff = capture(5)["opacity"]!
            try require(handoff > 0 && handoff < 0.09, "松开与选中交接丢失当前颜色")
            button.removeFromSuperview()
            try require(!button.feedbackIsAnimating, "移除日期视图后仍有帧驱动")
            window.contentView!.addSubview(button)
            try JSONSerialization.data(withJSONObject: probe.samples, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("day-feedback-\(index).json"))
        }
    }
}
#endif
