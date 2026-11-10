import AppKit

enum YearCalendarLayout {
    static let cornerRadius: CGFloat = 12
    static let cardInset: CGFloat = 6
    // 与外边距合计 12 pt，保留两列小月历的原有宽度。
    static let contentInset: CGFloat = 6
    static let monthContentInset: CGFloat = 8
    static let monthCornerRadius: CGFloat = 8
    static let monthHeight: CGFloat = 138
    static let monthRowHeight: CGFloat = 144
}

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

    func zoomMonthFrames(in root: NSView) -> [(Int, NSRect)] {
        [left, right].compactMap { button in
            guard let month = button.monthID, !button.visibleRect.isEmpty else { return nil }
            return (month, root.convert(button.bounds, from: button))
        }
    }

    override func layout() {
        super.layout()
        let inset = YearCalendarLayout.contentInset
        let gap: CGFloat = 16
        let width = max(0, (bounds.width - 2 * inset - gap) / 2)
        left.frame = NSRect(x: inset, y: 4, width: width, height: YearCalendarLayout.monthHeight)
        right.frame = NSRect(x: inset + width + gap, y: 4, width: width, height: YearCalendarLayout.monthHeight)
    }
}

// 保留 NSButton 的点击、键盘与辅助功能语义；日期栅格只绘制，不创建逐日子视图。
private final class MiniMonthButton: NSButton, CalendarZoomParticipant {
    var zoomHiddenDays: Set<Int> = []
    private var monthLayout: MiniMonthLayout?
    var monthID: Int? { monthLayout.map { $0.year * 100 + $0.month } }
    private var firstWeekday = 2
    private var todayDay: Int?
    private var onSelect: (() -> Void)?
    private var hovered = false
    private var drawingZoomCaption = false
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    private static let accent = NSColor(srgbRed: 0.89, green: 0.20, blue: 0.15, alpha: 1)
    private static let hoverColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.15, alpha: 1)
            : NSColor(srgbRed: 245.0 / 255, green: 245.0 / 255, blue: 245.0 / 255, alpha: 1)
    }
    private static let days = (1...31).map { CalendarGlyph(String($0), size: 9, color: .labelColor, monospaced: true) }
    private static let todayDays = (1...31).map { CalendarGlyph(String($0), size: 9, color: .white, monospaced: true) }
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"].map {
        CalendarGlyph($0, size: 8, color: CalendarSurface.secondaryTextColor)
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
        refreshHover()
        needsDisplay = true
    }

    @objc private func selectMonth() { onSelect?() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let month = monthLayout else { return }
        if drawingZoomCaption {
            drawCaption(month)
            return
        }
        clipBelowYearHeaders()
        if hovered || isHighlighted {
            (isHighlighted ? NSColor.labelColor.withAlphaComponent(0.08) : Self.hoverColor).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: YearCalendarLayout.monthCornerRadius,
                         yRadius: YearCalendarLayout.monthCornerRadius).fill()
        }
        if zoomHiddenDays.isEmpty {
            drawCaption(month)
        }
        for day in 1...month.dayCount {
            if zoomHiddenDays.contains(day) { continue }
            let rect = dateFrame(day, in: month)
            if todayDay == day {
                Self.accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 7, y: rect.minY, width: 14, height: 14)).fill()
                Self.todayDays[day - 1].draw(centeredIn: rect)
            } else {
                Self.days[day - 1].draw(centeredIn: rect)
            }
        }
    }

    private func drawCaption(_ month: MiniMonthLayout) {
        let inset = YearCalendarLayout.monthContentInset
        let heading = todayDay == nil ? Self.months[month.month - 1] : Self.currentMonths[month.month - 1]
        heading.draw(at: NSPoint(x: inset, y: inset))
        let columnWidth = (bounds.width - 2 * inset) / 7
        for column in 0..<7 {
            Self.weekdays[(firstWeekday - 1 + column) % 7]
                .draw(centeredIn: NSRect(x: inset + CGFloat(column) * columnWidth,
                                       y: inset + 22, width: columnWidth, height: 10))
        }
    }

    func zoomAnchors(month: Int, in root: NSView) -> [CalendarZoomAnchor] {
        guard let layout = monthLayout, layout.year * 100 + layout.month == month,
              visibleRect.height > 30 else { return [] }
        var result: [CalendarZoomAnchor] = []
        for day in 1...layout.dayCount {
            let rect = dateFrame(day, in: layout)
            if visibleRect.intersects(rect) {
                result.append(CalendarZoomAnchor(day: day, frame: root.convert(rect, from: self),
                    fontSize: 9, weight: NSFont.Weight.regular.rawValue,
                    color: todayDay == day ? .white : .labelColor, circle: todayDay == day))
            }
        }
        return result
    }

    func zoomCaption(month: Int, in root: NSView) -> CalendarZoomCaption? {
        guard monthID == month else { return nil }
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: YearCalendarLayout.monthContentInset + 37)
        // 反馈底色由整张画布拥有，标题快照只保留文字，避免半透明底色叠加。
        drawingZoomCaption = true
        defer { drawingZoomCaption = false }
        guard let image = NSImage(data: dataWithPDF(inside: rect)) else { return nil }
        return CalendarZoomCaption(image: image, frame: root.convert(rect, from: self))
    }

    private func dateFrame(_ day: Int, in month: MiniMonthLayout) -> NSRect {
        let index = (month.startingWeekday - firstWeekday + 7) % 7 + day - 1
        let inset = YearCalendarLayout.monthContentInset
        let width = (bounds.width - 2 * inset) / 7
        return NSRect(x: inset + CGFloat(index % 7) * width,
                      y: inset + 37 + CGFloat(index / 7) * 14, width: width, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        refreshHover()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(refreshHover), name: NSView.boundsDidChangeNotification, object: clip)
            }
            center.addObserver(self, selector: #selector(refreshHover), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(refreshHover), name: NSWindow.didResignKeyNotification, object: window)
        }
        refreshHover()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // 滚动和行复用可能使进入/离开事件过期，以当前窗口命中结果为准。
    @objc private func refreshHover() {
        // 悬浮年份行复用卡片背景，滚动后重新裁掉其下方的月份内容。
        needsDisplay = true
        var inside = false
        if let window, window.isKeyWindow, let content = window.contentView {
            let point = content.superview?.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                ?? window.mouseLocationOutsideOfEventStream
            inside = content.hitTest(point) === self
        }
        if hovered != inside {
            hovered = inside
        }
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        clipBelowYearHeaders()
        NSBezierPath(roundedRect: bounds, xRadius: YearCalendarLayout.monthCornerRadius,
                     yRadius: YearCalendarLayout.monthCornerRadius).fill()
    }

    private func clipBelowYearHeaders() {
        guard let table = enclosingScrollView?.documentView as? NSTableView else { return }
        let path = NSBezierPath(rect: bounds)
        path.windingRule = .evenOdd
        table.enumerateAvailableRowViews { row, _ in
            guard let header = row.view(atColumn: 0) as? YearHeaderView else { return }
            let covered = self.convert(header.bounds, from: header).intersection(self.bounds)
            if !covered.isNull && !covered.isEmpty { path.appendRect(covered) }
        }
        path.addClip()
    }
}

// AppKit 的悬浮分组行默认另画底色，必须与年份内容一起透明，才能共用卡片材质。
final class YearHeaderRowView: NSTableRowView {
    override var isOpaque: Bool { false }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawBackground(in dirtyRect: NSRect) {}
}

final class YearHeaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let edit = NSButton()
    private var onEdit: (() -> Void)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
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
        label.frame.origin = NSPoint(x: YearCalendarLayout.contentInset + YearCalendarLayout.monthContentInset,
                                     y: (bounds.height - label.frame.height) / 2)
        edit.frame = NSRect(x: label.frame.maxX + 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        let inset = YearCalendarLayout.contentInset
        NSRect(x: inset, y: 0, width: max(0, bounds.width - 2 * inset), height: 0.5).fill()
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
