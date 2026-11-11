#if DEBUG
import AppKit

@MainActor enum CalendarAgendaTitleSmoke {
    static func verify(title: NSTextField, root: NSView, name: String,
                       save: (NSView, String) throws -> Void) throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "DayOrder.AgendaTitle", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func capture() throws -> NSBitmapImageRep {
            guard let bitmap = title.bitmapImageRepForCachingDisplay(in: title.bounds) else {
                throw CocoaError(.coderInvalidValue)
            }
            title.cacheDisplay(in: title.bounds, to: bitmap)
            return bitmap
        }
        guard let window = title.window else { throw CocoaError(.coderInvalidValue) }
        window.makeFirstResponder(nil)
        defer { window.makeFirstResponder(nil) }
        let font = title.font
        let before = try capture()
        for attempt in 1...2 {
            let point = title.convert(NSPoint(x: 40, y: title.bounds.midY), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: 2, clickCount: 1, pressure: 0) else { throw CocoaError(.coderInvalidValue) }
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
            guard let editor = title.currentEditor() else { throw NSError(domain: "DayOrder.AgendaTitle", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "真实点击未进入标题选择状态：\(name)"]) }
            try require(editor.string == title.stringValue && title.font == font, "点击改变了标题或字体：\(name)")
            // 原生快照会重新组织文字选择层；保持实时焦点，仅取底层字段的绘制输出。
            let underneath: NSBitmapImageRep = try {
                guard let bitmap = title.bitmapImageRepForCachingDisplay(in: title.bounds),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.coderInvalidValue) }
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                let cg = context.cgContext
                cg.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
                cg.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
                cg.scaleBy(x: CGFloat(bitmap.pixelsWide) / title.bounds.width,
                           y: -CGFloat(bitmap.pixelsHigh) / title.bounds.height)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                title.draw(title.bounds)
                return bitmap
            }()
            var peak: CGFloat = 0
            for y in 0..<underneath.pixelsHigh {
                for x in 0..<underneath.pixelsWide {
                    peak = max(peak, underneath.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
            try require(peak < 0.1, "选择状态仍重复绘制标题：\(name)，底层透明度=\(peak)")
            try save(root, "agenda-title-\(name)-selected-\(attempt)")
            window.makeFirstResponder(nil)
            try require(title.currentEditor() == nil, "退出选择后仍保留文字层")
            let after = try capture()
            try require(before.pixelsWide == after.pixelsWide && before.pixelsHigh == after.pixelsHigh,
                        "点击改变了标题绘制尺寸")
            var error: CGFloat = 0
            for y in 0..<before.pixelsHigh {
                for x in 0..<before.pixelsWide {
                    guard let a = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let b = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    error += abs(a.redComponent * a.alphaComponent - b.redComponent * b.alphaComponent)
                        + abs(a.greenComponent * a.alphaComponent - b.greenComponent * b.alphaComponent)
                        + abs(a.blueComponent * a.alphaComponent - b.blueComponent * b.alphaComponent)
                        + abs(a.alphaComponent - b.alphaComponent)
                }
            }
            error /= CGFloat(before.pixelsWide * before.pixelsHigh * 4)
            try require(error < 0.01, "退出选择后没有恢复原始标题与渐隐：\(name)，像素误差=\(error)")
        }
        try save(root, "agenda-title-\(name)-restored")
    }
}
#endif
