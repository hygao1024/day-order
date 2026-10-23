import AppKit

struct MiniMonthLayout {
    let year: Int
    let month: Int
    let dayCount: Int
    let startingWeekday: Int
}

final class MonthPairView: NSView {
    private let left = MiniMonthButton(frame: .zero)
    private let right = MiniMonthButton(frame: .zero)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(left)
        addSubview(right)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(left: MiniMonthLayout, right: MiniMonthLayout, firstWeekday: Int,
                   today: DateComponents, select: @escaping (Int) -> Void) {
        self.left.configure(left, firstWeekday: firstWeekday, today: today) { select(left.month) }
        self.right.configure(right, firstWeekday: firstWeekday, today: today) { select(right.month) }
    }

    override func layout() {
        super.layout()
        let width = max(0, (bounds.width - 40) / 2)
        left.frame = NSRect(x: 12, y: 4, width: width, height: 122)
        right.frame = NSRect(x: 28 + width, y: 4, width: width, height: 122)
    }
}

// 保留 NSButton 的点击、键盘与辅助功能语义；日期栅格只绘制，不创建逐日子视图。
private final class MiniMonthButton: NSButton {
    private var monthLayout: MiniMonthLayout?
    private var firstWeekday = 2
    private var todayDay: Int?
    private var onSelect: (() -> Void)?
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    private static let accent = NSColor(srgbRed: 0.89, green: 0.20, blue: 0.15, alpha: 1)
    private static let days = (1...31).map { CalendarGlyph(String($0), size: 9, color: .labelColor, monospaced: true) }
    private static let todayDays = (1...31).map { CalendarGlyph(String($0), size: 9, color: .white, monospaced: true) }
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"].map {
        CalendarGlyph($0, size: 8, color: .secondaryLabelColor)
    }
    private static let months = (1...12).map {
        CalendarGlyph("\($0)月", size: 14, weight: .semibold, color: .labelColor)
    }
    private static let currentMonths = (1...12).map {
        CalendarGlyph("\($0)月", size: 14, weight: .semibold, color: accent)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        target = self
        action = #selector(selectMonth)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ month: MiniMonthLayout, firstWeekday: Int, today: DateComponents,
                   onSelect: @escaping () -> Void) {
        monthLayout = month
        self.firstWeekday = firstWeekday
        todayDay = today.year == month.year && today.month == month.month ? today.day : nil
        self.onSelect = onSelect
        title = "\(month.year)年\(month.month)月"
        setAccessibilityLabel(title)
        toolTip = "查看" + title
        hovered = false
        needsDisplay = true
    }

    @objc private func selectMonth() { onSelect?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let month = monthLayout else { return }
        if hovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.08 : 0.04).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let heading = todayDay == nil ? Self.months[month.month - 1] : Self.currentMonths[month.month - 1]
        heading.draw(at: NSPoint(x: 0, y: 0))
        let columnWidth = bounds.width / 7
        for column in 0..<7 {
            Self.weekdays[(firstWeekday - 1 + column) % 7]
                .draw(centeredIn: NSRect(x: CGFloat(column) * columnWidth, y: 22, width: columnWidth, height: 10))
        }
        let offset = (month.startingWeekday - firstWeekday + 7) % 7
        for day in 1...month.dayCount {
            let index = offset + day - 1
            let rect = NSRect(x: CGFloat(index % 7) * columnWidth, y: 37 + CGFloat(index / 7) * 14,
                              width: columnWidth, height: 14)
            if todayDay == day {
                Self.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 7, y: rect.minY, width: 14, height: 14)).fill()
                Self.todayDays[day - 1].draw(centeredIn: rect)
            } else {
                Self.days[day - 1].draw(centeredIn: rect)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }
}

final class YearHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let edit = NSButton()
    private var onEdit: (() -> Void)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .labelColor
        addSubview(label)
        edit.isBordered = false
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "输入年份")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        edit.contentTintColor = .secondaryLabelColor
        edit.imagePosition = .imageOnly
        edit.target = self
        edit.action = #selector(editYear)
        edit.toolTip = "输入年份"
        addSubview(edit)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(year: Int, onEdit: @escaping () -> Void) {
        label.stringValue = "\(year)年"
        edit.setAccessibilityLabel("跳转年份，当前\(year)年")
        self.onEdit = onEdit
        needsLayout = true
    }

    @objc private func editYear() { onEdit?() }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 10, y: (bounds.height - label.frame.height) / 2)
        edit.frame = NSRect(x: label.frame.maxX + 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        CalendarSurface.contentColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        NSRect(x: 12, y: 0, width: max(0, bounds.width - 24), height: 0.5).fill()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// 字形与尺寸在主线程共享，复用行与悬停重绘时无需重复构造、测量文字。
private struct CalendarGlyph {
    let text: NSAttributedString
    let size: NSSize

    init(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular,
         color: NSColor, monospaced: Bool = false) {
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        self.size = text.size()
    }

    func draw(at point: NSPoint) { text.draw(at: point) }
    func draw(centeredIn rect: NSRect) {
        draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
