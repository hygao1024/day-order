import AppKit
import DayOrderCore

struct CalendarAgendaSelection: Equatable {
    let date: Date
    let month: Date
}

@MainActor struct CalendarDayAgendaLayout {
    static let bodyLimit: CGFloat = 132
    static let maximumHeight: CGFloat = 32 + bodyLimit + 22 + 8
    static let titleWidth: CGFloat = 176
    let events: [CalendarEvent]
    let rowHeights: [CGFloat]
    let message: String?
    var contentHeight: CGFloat { rowHeights.reduce(0, +) }
    var bodyHeight: CGFloat { events.isEmpty ? 38 : min(Self.bodyLimit, contentHeight) }
    var height: CGFloat { 32 + bodyHeight + (contentHeight > bodyHeight ? 22 : 8) + 8 }

    init(events: [CalendarEvent], message: String?) {
        self.events = events
        self.message = message
        rowHeights = events.map { event in
            let title = (event.title as NSString).boundingRect(
                with: NSSize(width: Self.titleWidth - 4, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
            return max(40, ceil(title.height) + 30)
        }
    }
}

// 内层列表独立消费滚轮，包括到达边缘时；不能把剩余滚动传给月份时间线。
final class CalendarAgendaScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        let limit = max(0, documentView.bounds.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, contentView.bounds.minY - delta))))
        reflectScrolledClipView(contentView)
    }
}

final class CalendarDayAgendaView: NSView {
    let heading = NSTextField(labelWithString: "")
    let closeButton = NSButton(title: "收起 ⌃", target: nil, action: nil)
    let scroll = CalendarAgendaScrollView()
    let remaining = NSTextField(labelWithString: "")
    private let document = CalendarAgendaDocumentView()
    private var selection: CalendarAgendaSelection?
    private var layoutValue: CalendarDayAgendaLayout?
    private var close: (() -> Void)?
    var pointerX: CGFloat = 0
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("calendarDayAgenda")
        setAccessibilityElement(false)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        closeButton.font = .systemFont(ofSize: 10)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(collapse)
        closeButton.setAccessibilityLabel("收起当天日程")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateRemaining),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        remaining.font = .systemFont(ofSize: 10)
        remaining.textColor = CalendarSurface.secondaryTextColor
        remaining.alignment = .center
        [heading, closeButton, scroll, remaining].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(selection: CalendarAgendaSelection, layout: CalendarDayAgendaLayout,
                   engine: CalendarEngine, close: @escaping () -> Void) {
        let changedDay = self.selection != selection
        let changedContent = layoutValue?.events != layout.events || layoutValue?.message != layout.message
        self.selection = selection
        self.layoutValue = layout
        self.close = close
        let day = engine.info(for: selection.date)
        heading.stringValue = "\(day.month)月\(day.day)日 · \(layout.events.count)项日程"
        if changedDay || changedContent { document.configure(layout: layout, date: selection.date, engine: engine) }
        if changedDay { scroll.contentView.scroll(to: .zero) }
        needsLayout = true
        needsDisplay = true
    }

    func clear() {
        selection = nil
        layoutValue = nil
        close = nil
        heading.stringValue = ""
        remaining.stringValue = ""
        document.subviews.forEach { $0.removeFromSuperview() }
        document.frame = .zero
        scroll.contentView.scroll(to: .zero)
    }

    @objc private func collapse() { close?() }

    override func layout() {
        super.layout()
        guard let value = layoutValue else { return }
        heading.frame = NSRect(x: 10, y: 10, width: bounds.width - 64, height: 17)
        closeButton.frame = NSRect(x: bounds.width - 52, y: 6, width: 44, height: 24)
        scroll.frame = NSRect(x: 10, y: 32, width: bounds.width - 20, height: value.bodyHeight)
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                                height: max(value.bodyHeight, value.contentHeight))
        document.layoutSubtreeIfNeeded()
        let limit = max(0, document.bounds.height - scroll.contentSize.height)
        if scroll.contentView.bounds.minY > limit { scroll.contentView.scroll(to: NSPoint(x: 0, y: limit)) }
        remaining.frame = NSRect(x: 10, y: 32 + value.bodyHeight + 2, width: bounds.width - 20, height: 18)
        remaining.isHidden = value.contentHeight <= value.bodyHeight
        scroll.reflectScrolledClipView(scroll.contentView)
        updateRemaining()
    }

    @objc private func updateRemaining() {
        guard let value = layoutValue else { return }
        var bottom: CGFloat = 0
        let remainingCount = value.rowHeights.filter { height in
            bottom += height
            return bottom > scroll.contentView.bounds.maxY + 0.5
        }.count
        remaining.stringValue = remainingCount > 0 ? "下方还有 \(remainingCount) 项 ⌄" : "已显示全部日程"
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 4), xRadius: 8, yRadius: 8).fill()
        let x = min(bounds.width - 12, max(12, pointerX))
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: x - 5, y: 4))
        pointer.line(to: NSPoint(x: x, y: 0))
        pointer.line(to: NSPoint(x: x + 5, y: 4))
        pointer.close()
        pointer.fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

private final class CalendarAgendaDocumentView: NSView {
    private var heights: [CGFloat] = []
    override var isFlipped: Bool { true }

    func configure(layout: CalendarDayAgendaLayout, date: Date, engine: CalendarEngine) {
        subviews.forEach { $0.removeFromSuperview() }
        heights = layout.rowHeights
        if layout.events.isEmpty {
            let label = NSTextField(wrappingLabelWithString: layout.message ?? "当天暂无日程")
            label.font = .systemFont(ofSize: 11)
            label.textColor = CalendarSurface.secondaryTextColor
            addSubview(label)
        } else {
            for event in layout.events { addSubview(CalendarAgendaEventView(event: event, date: date, engine: engine)) }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let height = heights.isEmpty ? bounds.height : heights[index]
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}

private final class CalendarAgendaEventView: NSView {
    private let event: CalendarEvent
    private let time = NSTextField(labelWithString: "")
    private let title = NSTextField(wrappingLabelWithString: "")
    private let calendar = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    init(event: CalendarEvent, date: Date, engine: CalendarEngine) {
        self.event = event
        super.init(frame: .zero)
        title.stringValue = event.title
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.isSelectable = true
        title.maximumNumberOfLines = 0
        title.cell?.usesSingleLineMode = false
        title.cell?.wraps = true
        title.cell?.isScrollable = false
        title.lineBreakMode = .byWordWrapping
        calendar.stringValue = event.calendarTitle.isEmpty ? "系统日历" : event.calendarTitle
        calendar.font = .systemFont(ofSize: 10)
        calendar.textColor = CalendarSurface.secondaryTextColor
        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let info = engine.info(for: date)
        let localDay = local.date(from: DateComponents(year: info.year, month: info.month, day: info.day))!
        let nextDay = local.date(byAdding: .day, value: 1, to: localDay)!
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        if event.allDay { time.stringValue = "全天" }
        else {
            let start = event.start < localDay ? "续前日" : formatter.string(from: event.start)
            let end = event.end > nextDay ? "续次日" : event.end == nextDay ? "24:00" : formatter.string(from: event.end)
            time.stringValue = "\(start)–\(end)"
        }
        if !event.allDay {
            formatter.dateFormat = "M月d日 HH:mm"
            time.toolTip = "\(formatter.string(from: event.start)) 至 \(formatter.string(from: event.end))"
            time.setAccessibilityLabel(time.toolTip)
        }
        [time, title, calendar].forEach(addSubview)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        time.frame = NSRect(x: 10, y: 10, width: 72, height: 16)
        title.frame = NSRect(x: 88, y: 7, width: CalendarDayAgendaLayout.titleWidth, height: bounds.height - 26)
        calendar.frame = NSRect(x: 88, y: bounds.height - 17, width: CalendarDayAgendaLayout.titleWidth, height: 14)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(srgbRed: event.color.red, green: event.color.green, blue: event.color.blue, alpha: 1)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 10, width: 3, height: 15), xRadius: 1.5, yRadius: 1.5).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 1, y: bounds.height - 0.5, width: bounds.width - 10, height: 0.5).fill()
    }
}
