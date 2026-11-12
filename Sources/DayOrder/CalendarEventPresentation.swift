import AppKit
import DayOrderCore
import SwiftUI

struct CalendarEventToggle: NSViewRepresentable {
    @ObservedObject var events: SystemCalendarEvents

    func makeNSView(context: Context) -> CalendarEventModeButton {
        CalendarEventModeButton(events: events)
    }

    func updateNSView(_ button: CalendarEventModeButton, context: Context) {
        button.mode = events.mode
        button.toolTip = "日程显示：\(events.mode.title) · 点击切换为\(events.mode.next.title) · \(events.statusText)"
        button.setAccessibilityLabel("日程显示，当前\(events.mode.title)，点击切换为\(events.mode.next.title)")
    }
}

final class CalendarEventModeButton: NSButton {
    var mode = CalendarEventDisplay.hidden { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    private var isHovered: Bool {
        guard let window, window.isVisible else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
    }
    convenience init(events: SystemCalendarEvents) {
        self.init(frame: .zero)
        target = events
        action = #selector(SystemCalendarEvents.advance)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { needsDisplay = true }
    override func mouseExited(with event: NSEvent) { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted || isHovered {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        NSColor.labelColor.setStroke()
        func outline(_ rect: NSRect, radius: CGFloat) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = 1.5
            path.stroke()
        }
        switch mode {
        case .detailed, .compact:
            for y: CGFloat in [5, 13] {
                outline(NSRect(x: 3, y: y, width: 18, height: 6), radius: mode == .detailed ? 1.5 : 3)
                if mode == .detailed {
                    let path = NSBezierPath()
                    path.lineWidth = 1.3
                    path.lineCapStyle = .round
                    path.move(to: NSPoint(x: 6, y: y + 3))
                    path.line(to: NSPoint(x: y == 5 ? 18 : 12, y: y + 3))
                    path.stroke()
                }
            }
        case .dots, .hidden:
            outline(NSRect(x: 3, y: 8, width: 18, height: 7), radius: 3.5)
            if mode == .dots {
                let path = NSBezierPath()
                path.lineWidth = 1.3
                for x: CGFloat in [8, 12, 16] {
                    path.move(to: NSPoint(x: x, y: 8.5))
                    path.line(to: NSPoint(x: x, y: 14.5))
                }
                path.stroke()
            }
        }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
}

struct CalendarEventMarkerStyle: Animatable {
    var frame: CGRect
    var opacity: CGFloat
    var fillOpacity: CGFloat
    var detailOpacity: CGFloat
    var collapseX: CGFloat? = nil

    typealias AnimatableData = AnimatablePair<CGRect.AnimatableData, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>>
    var animatableData: AnimatableData {
        get { AnimatablePair(frame.animatableData, AnimatablePair(opacity, AnimatablePair(fillOpacity, detailOpacity))) }
        set {
            frame.animatableData = newValue.first
            opacity = newValue.second.first
            fillOpacity = newValue.second.second.first
            detailOpacity = newValue.second.second.second
        }
    }

    var collapsed: Self {
        var result = self
        let diameter: CGFloat = 3.5
        let center = CGPoint(x: collapseX ?? frame.midX, y: min(frame.midY, 46 - diameter / 2))
        result.frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        result.opacity = 0
        result.fillOpacity = 0.85
        result.detailOpacity = 0
        return result
    }
}

struct CalendarEventMarker {
    typealias ID = CalendarEvent.OccurrenceID
    let id: ID
    var style: CalendarEventMarkerStyle
    let color: CalendarEvent.Color
    let title: String
    var isMuted = false
    var continuesBefore = false
    var continuesAfter = false
}

@MainActor enum CalendarEventDrawing {
    private static let adjacentOpacity: CGFloat = 0.25

    static func markers(events: [CalendarEvent], mode: CalendarEventDisplay, width: CGFloat,
                        muted: Bool, dark: Bool, segments: [CalendarEventWeekLayout.Segment],
                        column: Int, overflow: Int) -> [CalendarEventMarker] {
        func marker(_ event: CalendarEvent, rect: CGRect, title: String) -> CalendarEventMarker {
            CalendarEventMarker(id: event.occurrenceID,
                style: CalendarEventMarkerStyle(frame: rect, opacity: muted ? adjacentOpacity : 1,
                    fillOpacity: mode == .detailed ? (dark ? 0.28 : 0.16) : 0.85,
                    detailOpacity: mode == .detailed ? 1 : 0, collapseX: width / 2),
                color: event.color, title: title, isMuted: muted)
        }
        if mode == .hidden { return [] }
        if mode == .dots {
            let count = min(3, events.count)
            return (0..<count).map { index in
                let offset = (CGFloat(index) - CGFloat(count - 1) / 2) * 5
                return marker(events[index], rect: CGRect(x: width / 2 + offset - 1.75, y: 50, width: 3.5, height: 3.5),
                              title: events[index].title)
            }
        }
        let inset: CGFloat = mode == .detailed ? 1 : 3
        var result = segments.map { segment in
            // 每格裁切同一个周内横条；文字只在周段开头出现，并可跨越日期列。
            let x = CGFloat(segment.columns.lowerBound - column) * width
            let left = segment.continuesBefore ? 0 : inset
            let right = segment.continuesAfter ? 0 : inset
            let rect = CGRect(x: x + left, y: 49 + CGFloat(segment.lane) * (mode == .detailed ? 14 : 4),
                width: CGFloat(segment.columns.count) * width - left - right, height: mode == .detailed ? 12 : 2)
            var value = marker(segment.event, rect: rect, title: segment.event.title)
            value.continuesBefore = segment.continuesBefore
            value.continuesAfter = segment.continuesAfter
            return value
        }
        if mode == .detailed, overflow > 0,
           let event = events.first(where: { event in !segments.contains { $0.event.occurrenceID == event.occurrenceID } }) {
            result.append(marker(event, rect: CGRect(x: 1, y: 63, width: width - 2, height: 12), title: "+\(overflow)项"))
        }
        return result
    }

    static func draw(marker: CalendarEventMarker, style: CalendarEventMarkerStyle, dark: Bool) {
        let rect = style.frame
        guard rect.width > 0, rect.height > 0, style.opacity > 0.000001,
              let cg = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let opacity = min(1, max(0, style.opacity))
        let tint = NSColor(srgbRed: marker.color.red, green: marker.color.green, blue: marker.color.blue, alpha: 1)
        cg.setAlpha(opacity)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        let square = rect.height / 2 * min(1, max(0, (rect.width - 3.5) / 10.5))
        if marker.continuesBefore {
            pill.appendRect(CGRect(x: rect.minX, y: rect.minY, width: square, height: rect.height))
        }
        if marker.continuesAfter {
            pill.appendRect(CGRect(x: rect.maxX - square, y: rect.minY, width: square, height: rect.height))
        }
        tint.withAlphaComponent(min(1, max(0, style.fillOpacity))).setFill()
        pill.fill()
        let room = min(1, max(0, (rect.height - 3.5) / 8.5)) * min(1, max(0, (rect.width - 14) / 12))
        let details = min(1, max(0, style.detailOpacity)) * room
        guard details > 0.000001 else { return }
        pill.addClip()
        cg.setAlpha(opacity * details)
        let diameter = min(10, max(0, rect.height - 2))
        let badge = CGRect(x: rect.minX + 1, y: rect.midY - diameter / 2, width: diameter, height: diameter)
        tint.setFill()
        NSBezierPath(ovalIn: badge).fill()
        let scale = max(2, hypot(cg.ctm.a, cg.ctm.b), hypot(cg.ctm.c, cg.ctm.d))
        let iconRect = badge.insetBy(dx: 1.5, dy: 1.5)
        if let symbol = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.white])),
           let icon = rasterizedDetail(size: iconRect.size, scale: scale, drawing: { _ in
               symbol.draw(in: CGRect(origin: .zero, size: iconRect.size), from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
           }) {
            // 系统符号的镂空在 PDF 回放中会丢失；只嵌入已合成的透明位图。
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        let textRect = CGRect(x: rect.minX + 12, y: rect.minY, width: max(0, rect.width - 14), height: rect.height)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: textRect)
        // 邻月深色标签只减少文字淡化，底色和图标保留原层级，并继续跟随动画透明度。
        let textOpacity = dark && marker.isMuted ? min(1, opacity / adjacentOpacity * 0.90) : opacity
        cg.setAlpha(textOpacity * details)
        let foreground = tint.blended(withFraction: dark ? 0.75 : 0.40, of: dark ? .white : .black) ?? .labelColor
        let text = NSAttributedString(string: marker.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: foreground
        ])
        if text.size().width > textRect.width,
           let image = fadedTitle(text, size: textRect.size, scale: scale) {
            image.draw(in: textRect, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
        } else {
            text.draw(at: CGPoint(x: textRect.minX, y: textRect.midY - text.size().height / 2))
        }
    }

    static func fadedTitle(_ text: NSAttributedString, size: CGSize, scale: CGFloat, fadeWidth: CGFloat = 5) -> NSImage? {
        guard let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.black.cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) else { return nil }
        return rasterizedDetail(size: size, scale: scale) { cg in
            text.draw(at: CGPoint(x: 0, y: (size.height - text.size().height) / 2))
            // PDF 快照无法保留 destinationIn 遮罩；先在透明位图内完成渐隐，再交给画布合成。
            cg.setBlendMode(.destinationIn)
            cg.drawLinearGradient(fade, start: CGPoint(x: size.width - fadeWidth, y: 0),
                                  end: CGPoint(x: size.width, y: 0), options: [.drawsBeforeStartLocation])
        }
    }

    private static func rasterizedDetail(size: CGSize, scale: CGFloat, drawing: (CGContext) -> Void) -> NSImage? {
        guard size.width > 0, size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        cg.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        cg.scaleBy(x: CGFloat(bitmap.pixelsWide) / size.width, y: -CGFloat(bitmap.pixelsHigh) / size.height)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        drawing(cg)
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}
