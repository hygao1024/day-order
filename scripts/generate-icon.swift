import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let body = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 190, yRadius: 190)
        NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.95, alpha: 1).setFill()
        body.fill()
        context.saveGState()
        body.addClip()
        NSColor(calibratedRed: 0.89, green: 0.20, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 72, y: 692, width: 880, height: 260)).fill()
        context.restoreGState()
        let text: NSString = "日"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 455, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)
        ]
        let bounds = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (1024 - bounds.width) / 2, y: 145), withAttributes: attributes)
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
