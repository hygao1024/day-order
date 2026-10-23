import AppKit

@MainActor
enum MenuBarIcon {
    static func calendar(day: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 20), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 22, height: 16),
                         xRadius: 3, yRadius: 3).fill()
            let text = String(day) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
            let size = text.size(withAttributes: attributes)
            // 镂空数字使实心徽标随系统模板着色，并保留数字与底色的对比。
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.setBlendMode(.destinationOut)
            text.draw(at: NSPoint(x: (rect.width - size.width) / 2,
                                 y: (rect.height - size.height) / 2), withAttributes: attributes)
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(day)日"
        return image
    }
}
