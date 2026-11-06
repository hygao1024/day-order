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

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        NSColor.systemRed.setStroke()
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
        let center = CGPoint(x: frame.midX, y: min(frame.midY, 46 - diameter / 2))
        result.frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        result.opacity = 0
        result.fillOpacity = 0.85
        result.detailOpacity = 0
        return result
    }
}

struct CalendarEventMarker {
    struct ID: Hashable {
        let event: String
        let start: Date
    }
    let id: ID
    var style: CalendarEventMarkerStyle
    let color: CalendarEvent.Color
    let title: String
}

@MainActor enum CalendarEventDrawing {
    static func frames(count: Int, mode: CalendarEventDisplay, width: CGFloat) -> [NSRect] {
        switch mode {
        case .hidden: return []
        case .detailed:
            return (0..<min(2, count)).map { NSRect(x: 1, y: 45 + CGFloat($0) * 14, width: width - 2, height: 12) }
        case .compact:
            return (0..<min(3, count)).map { NSRect(x: 3, y: 45 + CGFloat($0) * 4, width: width - 6, height: 2) }
        case .dots:
            let visible = min(3, count)
            return (0..<visible).map { index in
                let offset = (CGFloat(index) - CGFloat(visible - 1) / 2) * 5
                return NSRect(x: width / 2 + offset - 1.75, y: 46, width: 3.5, height: 3.5)
            }
        }
    }

    static func markers(events: [CalendarEvent], mode: CalendarEventDisplay, width: CGFloat,
                        muted: Bool, dark: Bool) -> [CalendarEventMarker] {
        frames(count: events.count, mode: mode, width: width).enumerated().map { index, rect in
            let event = events[index]
            return CalendarEventMarker(id: .init(event: event.id, start: event.start),
                style: CalendarEventMarkerStyle(frame: rect, opacity: muted ? 0.25 : 1,
                    fillOpacity: mode == .detailed ? (dark ? 0.28 : 0.16) : 0.85,
                    detailOpacity: mode == .detailed ? 1 : 0),
                color: event.color, title: index == 1 && events.count > 2 && mode == .detailed ? "+\(events.count - 1)项" : event.title)
        }
    }

    static func draw(events: [CalendarEvent], mode: CalendarEventDisplay, in view: NSView, muted: Bool) {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for marker in markers(events: events, mode: mode, width: view.bounds.width, muted: muted, dark: dark) {
            draw(marker: marker, style: marker.style, dark: dark)
        }
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
        NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 6, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [.white]))?
            .draw(in: badge.insetBy(dx: 1.5, dy: 1.5), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: true, hints: nil)
        let textRect = CGRect(x: rect.minX + 12, y: rect.minY, width: max(0, rect.width - 14), height: rect.height)
        cg.saveGState()
        cg.clip(to: textRect)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        let foreground = tint.blended(withFraction: dark ? 0.55 : 0.40, of: dark ? .white : .black) ?? .labelColor
        let text = NSAttributedString(string: marker.title, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: foreground
        ])
        text.draw(at: CGPoint(x: textRect.minX, y: textRect.midY - text.size().height / 2))
        if text.size().width > textRect.width,
           let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [NSColor.black.cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) {
            cg.setBlendMode(.destinationIn)
            cg.drawLinearGradient(fade, start: CGPoint(x: textRect.maxX - 5, y: 0),
                                  end: CGPoint(x: textRect.maxX, y: 0), options: [.drawsBeforeStartLocation])
        }
        cg.endTransparencyLayer()
        cg.restoreGState()
    }
}
