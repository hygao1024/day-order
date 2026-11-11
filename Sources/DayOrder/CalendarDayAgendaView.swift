import AppKit
import DayOrderCore

struct CalendarAgendaSelection: Equatable {
    let date: Date
    let month: Date
}

@MainActor final class CalendarDayAgendaLayout {
    #if DEBUG
    static var measurements = 0
    #endif
    static let bodyLimit: CGFloat = 132
    static let topInset: CGFloat = 12
    static let maximumHeight: CGFloat = topInset + bodyLimit + 22 + 8
    static let titleWidth: CGFloat = 176
    let events: [CalendarEvent]
    let rowHeights: [CGFloat]
    let message: String?
    var contentHeight: CGFloat { rowHeights.reduce(0, +) }
    var bodyHeight: CGFloat { events.isEmpty ? 38 : min(Self.bodyLimit, contentHeight) }
    var height: CGFloat { Self.topInset + bodyHeight + (contentHeight > bodyHeight ? 22 : 8) + 8 }

    init(events: [CalendarEvent], message: String?) {
        #if DEBUG
        Self.measurements += 1
        #endif
        self.events = events
        self.message = message
        rowHeights = Array(repeating: 44, count: events.count)
    }
}

// 有溢出时内层列表独立消费滚轮，包括到达边缘时；内容全部可见则交给外层日历。
final class CalendarAgendaScrollView: NSScrollView {
    #if DEBUG
    var wheelEvents = 0
    #endif
    override func scrollWheel(with event: NSEvent) {
        #if DEBUG
        wheelEvents += 1
        #endif
        guard let documentView else { return }
        let limit = max(0, documentView.bounds.height - contentView.bounds.height)
        guard limit > 0.5 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        contentView.scroll(to: NSPoint(x: 0, y: min(limit, max(0, contentView.bounds.minY - delta))))
        reflectScrolledClipView(contentView)
    }
}

final class CalendarDayAgendaView: NSView {
    let scroll = CalendarAgendaScrollView()
    let remaining = NSTextField(labelWithString: "")
    private let document = CalendarAgendaDocumentView()
    private var selection: CalendarAgendaSelection?
    private var layoutValue: CalendarDayAgendaLayout?
    var itemCount: Int { layoutValue?.events.count ?? 0 }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("calendarDayAgenda")
        setAccessibilityElement(false)
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
        [scroll, remaining].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(selection: CalendarAgendaSelection, layout: CalendarDayAgendaLayout,
                   engine: CalendarEngine) {
        let changedDay = self.selection != selection
        let changedContent = layoutValue !== layout
        guard changedDay || changedContent else { return }
        self.selection = selection
        self.layoutValue = layout
        let day = engine.info(for: selection.date)
        scroll.setAccessibilityLabel("\(day.month)月\(day.day)日 · \(layout.events.count)项日程")
        document.configure(layout: layout, date: selection.date, engine: engine)
        if changedDay { scroll.contentView.scroll(to: .zero) }
        needsLayout = true
        needsDisplay = true
    }

    func clear() {
        guard selection != nil else { return }
        selection = nil
        layoutValue = nil
        scroll.setAccessibilityLabel(nil)
        remaining.stringValue = ""
        document.clear()
        document.frame = .zero
        scroll.contentView.scroll(to: .zero)
    }

    override func layout() {
        super.layout()
        guard let value = layoutValue else { return }
        scroll.frame = NSRect(x: 10, y: CalendarDayAgendaLayout.topInset, width: bounds.width - 20, height: value.bodyHeight)
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                                height: max(value.bodyHeight, value.contentHeight))
        document.layoutSubtreeIfNeeded()
        let limit = max(0, document.bounds.height - scroll.contentSize.height)
        if scroll.contentView.bounds.minY > limit { scroll.contentView.scroll(to: NSPoint(x: 0, y: limit)) }
        remaining.frame = NSRect(x: 10, y: CalendarDayAgendaLayout.topInset + value.bodyHeight + 2, width: bounds.width - 20, height: 18)
        remaining.isHidden = value.contentHeight <= value.bodyHeight
        scroll.reflectScrolledClipView(scroll.contentView)
        updateRemaining()
    }

    @objc private func updateRemaining() {
        guard let value = layoutValue else { return }
        document.updateVisibleRows()
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
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

private final class CalendarAgendaDocumentView: NSView {
    private var value: CalendarDayAgendaLayout?
    private var date: Date?
    private var engine: CalendarEngine?
    private var offsets: [CGFloat] = []
    private var rows: [Int: CalendarAgendaEventView] = [:]
    override var isFlipped: Bool { true }

    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        offsets.removeAll()
        value = nil
        date = nil
        engine = nil
    }

    func configure(layout: CalendarDayAgendaLayout, date: Date, engine: CalendarEngine) {
        clear()
        value = layout
        self.date = date
        self.engine = engine
        var y: CGFloat = 0
        offsets = layout.rowHeights.map { height in
            defer { y += height }
            return y
        }
        if layout.events.isEmpty {
            let label = NSTextField(wrappingLabelWithString: layout.message ?? "当天暂无日程")
            label.font = .systemFont(ofSize: 11)
            label.textColor = CalendarSurface.secondaryTextColor
            addSubview(label)
        }
        needsLayout = true
    }

    func updateVisibleRows() {
        guard let value, !value.events.isEmpty, let date, let engine,
              let clip = enclosingScrollView?.contentView else { return }
        // 只按内层视口取样；外层日历裁切不能使展开动画的离屏端点缺少内容。
        let visible = convert(clip.bounds, from: clip).insetBy(dx: 0, dy: -40)
        let needed = Set(value.events.indices.filter {
            offsets[$0] < visible.maxY && offsets[$0] + value.rowHeights[$0] > visible.minY
        })
        for index in Array(rows.keys) where !needed.contains(index) {
            rows.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in needed.sorted() {
            let row: CalendarAgendaEventView
            if let existing = rows[index] { row = existing }
            else {
                row = CalendarAgendaEventView(event: value.events[index], date: date, engine: engine,
                                              showsSeparator: index < value.events.count - 1)
                rows[index] = row
                addSubview(row)
            }
            row.frame = NSRect(x: 0, y: offsets[index], width: bounds.width, height: value.rowHeights[index])
        }
    }

    override func layout() {
        super.layout()
        if value?.events.isEmpty == true { subviews.first?.frame = bounds }
        else { updateVisibleRows() }
    }
}

private final class CalendarAgendaEventView: NSView {
    private let event: CalendarEvent
    private let showsSeparator: Bool
    private let time = NSTextField(labelWithString: "")
    private let title = CalendarAgendaTitleField(labelWithString: "")
    private let calendar = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    init(event: CalendarEvent, date: Date, engine: CalendarEngine, showsSeparator: Bool) {
        self.showsSeparator = showsSeparator
        self.event = event
        super.init(frame: .zero)
        title.stringValue = event.title
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.isSelectable = true
        title.toolTip = event.title
        title.maximumNumberOfLines = 1
        title.cell?.usesSingleLineMode = true
        title.cell?.wraps = false
        title.cell?.isScrollable = false
        title.lineBreakMode = .byClipping
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
        title.frame = NSRect(x: 88, y: 7, width: CalendarDayAgendaLayout.titleWidth, height: 16)
        calendar.frame = NSRect(x: 88, y: bounds.height - 17, width: CalendarDayAgendaLayout.titleWidth, height: 14)
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor(srgbRed: event.color.red, green: event.color.green, blue: event.color.blue, alpha: 1)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 10, width: 3, height: 15), xRadius: 1.5, yRadius: 1.5).fill()
        if showsSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: 1, y: bounds.height - 0.5, width: bounds.width - 10, height: 0.5).fill()
        }
    }
}

private final class CalendarAgendaTitleField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: stringValue.components(separatedBy: .newlines).joined(separator: " "),
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
                         .foregroundColor: textColor ?? NSColor.labelColor])
        let rect = bounds.insetBy(dx: 2, dy: 0)
        guard text.size().width > rect.width,
              let cg = NSGraphicsContext.current?.cgContext else { super.draw(dirtyRect); return }
        let scale = max(2, hypot(cg.ctm.a, cg.ctm.b), hypot(cg.ctm.c, cg.ctm.d))
        guard let image = CalendarEventDrawing.fadedTitle(text, size: rect.size, scale: scale, fadeWidth: 14) else {
            super.draw(dirtyRect)
            return
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
