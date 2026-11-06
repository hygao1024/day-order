import AppKit
import DayOrderCore
import SwiftUI

struct CalendarEventMenu: NSViewRepresentable {
    @ObservedObject var events: SystemCalendarEvents

    func makeNSView(context: Context) -> CalendarEventModeButton {
        let button = CalendarEventModeButton(frame: .zero)
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        return button
    }

    func updateNSView(_ button: CalendarEventModeButton, context: Context) {
        button.mode = events.mode
        button.toolTip = "日程显示：\(events.mode.title) · \(events.statusText)"
        button.setAccessibilityLabel("日程显示，\(events.mode.title)")
    }

    func makeCoordinator() -> Coordinator { Coordinator(events: events) }

    @MainActor final class Coordinator: NSObject {
        let events: SystemCalendarEvents
        init(events: SystemCalendarEvents) { self.events = events }

        @objc func openMenu(_ sender: NSButton) {
            let menu = makeMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu(title: "日程显示")
            for mode in CalendarEventDisplay.allCases {
                let item = NSMenuItem(title: mode.title, action: #selector(choose(_:)), keyEquivalent: "")
                item.representedObject = mode.rawValue
                item.target = self
                item.state = events.mode == mode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let status = NSMenuItem(title: events.statusText, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            if events.authorization == .denied || events.authorization == .restricted || events.authorization == .writeOnly {
                let item = NSMenuItem(title: "打开系统日历权限设置…", action: #selector(openSettings), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            if events.errorMessage != nil || events.authorization == .fullAccess {
                let item = NSMenuItem(title: "重新读取日程", action: #selector(retry), keyEquivalent: "")
                item.target = self
                item.isEnabled = events.mode != .hidden
                menu.addItem(item)
            }
            return menu
        }

        @objc func choose(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let mode = CalendarEventDisplay(rawValue: raw) else { return }
            events.choose(mode)
        }
        @objc private func openSettings() { events.openPrivacySettings() }
        @objc private func retry() { events.choose(events.mode) }
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

    static func draw(events: [CalendarEvent], mode: CalendarEventDisplay, in view: NSView, muted: Bool) {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for (index, rect) in frames(count: events.count, mode: mode, width: view.bounds.width).enumerated() {
            let event = events[index]
            let tint = NSColor(srgbRed: event.color.red, green: event.color.green, blue: event.color.blue, alpha: 1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let cg = NSGraphicsContext.current!.cgContext
            cg.clip(to: view.bounds)
            cg.setAlpha(muted ? 0.25 : 1)
            let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            tint.withAlphaComponent(mode == .detailed ? (dark ? 0.28 : 0.16) : 0.85).setFill()
            pill.fill()
            guard mode == .detailed else { continue }
            let badge = NSRect(x: rect.minX + 1, y: rect.minY + 1, width: 10, height: 10)
            tint.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let glyph = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 6, weight: .medium))
            glyph?.withSymbolConfiguration(.init(paletteColors: [.white]))?
                .draw(in: badge.insetBy(dx: 1.5, dy: 1.5), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
            let textRect = NSRect(x: rect.minX + 12, y: rect.minY, width: max(0, rect.width - 14), height: rect.height)
            cg.saveGState()
            cg.clip(to: textRect)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            let more = index == 1 && events.count > 2
            let title = more ? "+\(events.count - 1)项" : event.title
            let foreground = tint.blended(withFraction: dark ? 0.55 : 0.40, of: dark ? .white : .black) ?? .labelColor
            let text = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: foreground
            ])
            text.draw(at: NSPoint(x: textRect.minX, y: textRect.midY - text.size().height / 2))
            if text.size().width > textRect.width,
               let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [NSColor.black.cgColor, NSColor.clear.cgColor] as CFArray,
                                     locations: [0, 1]) {
                cg.setBlendMode(.destinationIn)
                cg.drawLinearGradient(fade, start: CGPoint(x: textRect.maxX - 5, y: 0),
                                      end: CGPoint(x: textRect.maxX, y: 0), options: [.drawsBeforeStartLocation])
            }
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
    }
}
