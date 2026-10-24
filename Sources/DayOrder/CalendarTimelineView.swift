import AppKit
import DayOrderCore
import SwiftUI

struct CalendarContentOptions: Equatable {
    let traditional: Bool
    let civil: Bool
    let western: Bool
    let worldDays: Bool
    let solarTerms: Bool
    let holidaySchedule: Bool

    func annotations(for day: DayInfo) -> [Annotation] {
        day.annotations.filter {
            switch $0.kind {
            case .traditional: traditional
            case .civil: civil
            case .western: western
            case .worldDay: worldDays
            case .solarTerm: solarTerms
            }
        }
    }
}

struct CalendarTimelineView: NSViewRepresentable {
    static let viewportHeight: CGFloat = 286
    @ObservedObject var model: CalendarModel
    let firstWeekday: Int
    let options: CalendarContentOptions

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, firstWeekday: firstWeekday, options: options)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CalendarTimelineScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        let table = NSTableView()
        table.identifier = NSUserInterfaceItemIdentifier("calendarTimeline")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("week"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        scroll.onActivity = { [weak coordinator = context.coordinator] in coordinator?.beginInteraction() }
        scroll.onPause = { [weak coordinator = context.coordinator] in coordinator?.scheduleSnap() }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.liveScrollBegan),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.liveScrollEnded),
            name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(firstWeekday: firstWeekday, options: options)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: CalendarModel
        private(set) var timeline: CalendarTimeline
        weak var table: NSTableView?
        private var options: CalendarContentOptions
        private var revision: Int?
        private var today: Date
        private var selection: Date
        private var holidayRevision: Int
        private var updating = false
        private var scrollTask: Task<Void, Never>?
        private var scrollSerial = 0
        private var days: [Date: [DayInfo]] = [:]
        private struct MonthSnap {
            let month: Date
            let weeks: ClosedRange<Int>
            var heading: Int { weeks.lowerBound - 1 }
        }
        private var snapped: MonthSnap?
        private var snapTask: Task<Void, Never>?
        private var snapSerial = 0
        private var animatingSnap = false
        private var liveScrolling = false

        init(model: CalendarModel, firstWeekday: Int, options: CalendarContentOptions) {
            self.model = model
            timeline = CalendarTimeline(engine: model.engine, firstWeekday: firstWeekday)
            self.options = options
            today = model.today
            selection = model.selection
            holidayRevision = model.holidayRevision
        }

        func disconnect() {
            cancelSnap()
            if let scroll = table?.enclosingScrollView as? CalendarTimelineScrollView {
                scroll.onActivity = nil
                scroll.onPause = nil
            }
            scrollSerial += 1
            scrollTask?.cancel()
            scrollTask = nil
            NotificationCenter.default.removeObserver(self)
            table?.delegate = nil
            table?.dataSource = nil
            table = nil
        }

        func update(firstWeekday: Int, options: CalendarContentOptions) {
            guard let table, table.enclosingScrollView != nil else { return }
            updating = true
            defer { updating = false }
            let rebuilt = firstWeekday != timeline.firstWeekday
            let changed = self.options != options || today != model.today || selection != model.selection
                || holidayRevision != model.holidayRevision
            self.options = options
            today = model.today
            selection = model.selection
            holidayRevision = model.holidayRevision
            if rebuilt {
                cancelSnap()
                if let snapped { table.unhideRows(at: IndexSet(integer: snapped.heading), withAnimation: []) }
                snapped = nil
                timeline = CalendarTimeline(engine: model.engine, firstWeekday: firstWeekday)
                days.removeAll()
                table.reloadData()
            } else if changed {
                let range = table.rows(in: table.visibleRect)
                for row in range.location..<NSMaxRange(range) {
                    if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CalendarWeekView {
                        configure(view, row: row)
                    }
                }
            }
            if revision != model.calendarScrollRevision || rebuilt {
                cancelSnap()
                scrollSerial += 1
                scrollTask?.cancel()
                scrollTask = nil
                let restoring = (revision == nil || rebuilt) ? model.calendarViewport : nil
                let restoredMonth = model.calendarSnappedMonth
                revision = model.calendarScrollRevision
                if let restoring, restoredMonth == nil {
                    setSnapLayout(nil)
                    moveViewport(to: table.rect(ofRow: timeline.weekRow(containing: restoring.date, inMonth: restoring.month)).minY + restoring.offset)
                } else {
                    let layout = monthLayout(for: restoredMonth ?? model.calendarScrollTarget)
                    setSnapLayout(layout)
                    if let layout { moveViewport(to: table.rect(ofRow: layout.weeks.lowerBound).minY) }
                }
            }
        }

        private func monthLayout(for date: Date) -> MonthSnap? {
            guard model.engine.isSupported(date) else { return nil }
            let month = model.engine.monthStart(date)
            let last = model.engine.addingDays(-1, to: model.engine.addingMonths(1, to: month))
            let firstRow = timeline.weekRow(containing: month)
            let lastRow = timeline.weekRow(containing: last)
            return MonthSnap(month: month, weeks: firstRow...lastRow)
        }

        private func cancelSnap() {
            snapSerial += 1
            snapTask?.cancel()
            snapTask = nil
            animatingSnap = false
        }

        // 行高和标题只在整月状态切换时改变；导航与恢复均使用日期锚点，而非长列表的估算绝对坐标。
        private func setSnapLayout(_ layout: MonthSnap?) {
            guard let table else { return }
            var changedRows = IndexSet()
            if let snapped { changedRows.formUnion(IndexSet(snapped.weeks)) }
            if let layout { changedRows.formUnion(IndexSet(layout.weeks)) }
            if let snapped { table.unhideRows(at: IndexSet(integer: snapped.heading), withAnimation: []) }
            snapped = layout
            model.calendarSnappedMonth = layout?.month
            if let layout { table.hideRows(at: IndexSet(integer: layout.heading), withAnimation: []) }
            table.noteHeightOfRows(withIndexesChanged: changedRows)
            table.layoutSubtreeIfNeeded()
        }

        private func moveViewport(to y: CGFloat) {
            guard let table, let scroll = table.enclosingScrollView else { return }
            let limit = max(0, table.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: table.convert(NSPoint(x: 0, y: min(max(0, y), limit)), to: scroll.contentView))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func beginInteraction() {
            cancelSnap()
            guard let table, snapped != nil else { return }
            updating = true
            defer { updating = false }
            let row = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
            let offset = row >= 0 ? table.visibleRect.minY - table.rect(ofRow: row).minY : 0
            setSnapLayout(nil)
            if row >= 0 { moveViewport(to: table.rect(ofRow: row).minY + offset) }
        }

        @objc func liveScrollBegan() {
            liveScrolling = true
            beginInteraction()
        }

        @objc func liveScrollEnded() {
            liveScrolling = false
            scheduleSnap()
        }

        func scheduleSnap() {
            cancelSnap()
            guard !liveScrolling,
                  let scroll = table?.enclosingScrollView as? CalendarTimelineScrollView,
                  !scroll.gestureActive else { return }
            let serial = snapSerial
            let requestedRevision = model.calendarScrollRevision
            snapTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
                guard let self else { return }
                defer { if snapSerial == serial { snapTask = nil; animatingSnap = false } }
                guard !Task.isCancelled, !liveScrolling, !scroll.gestureActive,
                      requestedRevision == model.calendarScrollRevision,
                      !model.showingSettings, !model.showingYearOverview,
                      let table, table.window?.isVisible == true,
                      let candidate = nearbyMonth() else { return }
                animatingSnap = true
                updating = true
                let first = candidate.weeks.lowerBound
                let offset = table.visibleRect.minY - table.rect(ofRow: first).minY
                setSnapLayout(candidate)
                moveViewport(to: table.rect(ofRow: first).minY + offset)
                updating = false
                model.browseMonth(containing: candidate.month)
                let steps = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 10
                for step in 1...steps {
                    guard !Task.isCancelled, snapSerial == serial else { return }
                    let progress = CGFloat(step) / CGFloat(steps)
                    let remaining = pow(1 - progress, 3)
                    moveViewport(to: table.rect(ofRow: first).minY + offset * remaining)
                    if step < steps {
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    }
                }
                model.calendarViewport = (timeline.rows[first].date, candidate.month, 0)
            }
        }

        private func nearbyMonth() -> MonthSnap? {
            guard let table else { return nil }
            let top = table.visibleRect.minY
            let range = table.rows(in: NSRect(x: 0, y: max(0, top - 100), width: table.bounds.width, height: 200))
            var nearest: (distance: CGFloat, date: Date)?
            for row in range.location..<NSMaxRange(range) where timeline.rows.indices.contains(row) {
                guard case .month(let date) = timeline.rows[row] else { continue }
                let distance = abs(table.rect(ofRow: timeline.weekRow(containing: date)).minY - top)
                if distance <= 44 && distance < (nearest?.distance ?? .infinity) { nearest = (distance, date) }
            }
            return nearest.flatMap { monthLayout(for: $0.date) }
        }

        @objc func scrolled() {
            guard !updating, !animatingSnap, scrollTask == nil else { return }
            let requestedRevision = model.calendarScrollRevision
            scrollSerial += 1
            let serial = scrollSerial
            scrollTask = Task { [weak self] in
                await Task.yield()
                guard let self else { return }
                defer { if scrollSerial == serial { scrollTask = nil } }
                guard !Task.isCancelled, requestedRevision == model.calendarScrollRevision,
                      let table, table.enclosingScrollView != nil else { return }
                let row = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
                guard timeline.rows.indices.contains(row) else { return }
                let item = timeline.rows[row]
                let weekRow = timeline.weekRow(containing: item.date, inMonth: item.sectionMonth)
                model.calendarViewport = (item.date, item.sectionMonth,
                                          table.visibleRect.minY - table.rect(ofRow: weekRow).minY)
                model.browseMonth(containing: snapped?.month ?? item.sectionMonth)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { timeline.rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch timeline.rows[row] {
            case .month: return 30
            case .week:
                if let snapped, snapped.weeks.contains(row) {
                    let scale = tableView.window?.backingScaleFactor ?? 2
                    let unit = CalendarTimelineView.viewportHeight * scale / CGFloat(snapped.weeks.count)
                    let index = CGFloat(row - snapped.weeks.lowerBound)
                    return (floor((index + 1) * unit) - floor(index * unit)) / scale
                }
                return 56
            }
        }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch timeline.rows[row] {
            case .month(let date):
                let identifier = NSUserInterfaceItemIdentifier("timelineMonth")
                let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? CalendarMonthLabel
                    ?? CalendarMonthLabel(frame: .zero)
                view.identifier = identifier
                let parts = model.engine.calendar.dateComponents([.year, .month], from: date)
                view.label.stringValue = parts.month == 1 ? "\(parts.year!)年1月" : "\(parts.month!)月"
                return view
            case .week:
                let identifier = NSUserInterfaceItemIdentifier("timelineWeek")
                let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? CalendarWeekView
                    ?? CalendarWeekView(frame: .zero)
                view.identifier = identifier
                configure(view, row: row)
                return view
            }
        }

        private func configure(_ view: CalendarWeekView, row: Int) {
            guard case .week(let start, let sectionMonth) = timeline.rows[row] else { return }
            let values: [DayInfo]
            if let cached = days[start] { values = cached }
            else {
                values = (0..<7).map { model.engine.info(for: model.engine.addingDays($0, to: start)) }
                // 缓存有界且属于当前滚动视图，长距离浏览不积累整部历法。
                if days.count >= 128 { days.removeAll(keepingCapacity: true) }
                days[start] = values
            }
            view.configure(days: values, sectionMonth: sectionMonth, model: model, options: options)
        }
    }
}

private final class CalendarMonthLabel: NSView {
    let label = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 12, y: 6, width: bounds.width - 24, height: 20)
    }
}

final class CalendarWeekView: NSView {
    private let buttons = (0..<7).map { _ in CalendarDayButton(frame: .zero) }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        buttons.forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(days: [DayInfo], sectionMonth: Date, model: CalendarModel, options: CalendarContentOptions) {
        for (button, day) in zip(buttons, days) {
            button.configure(day: day, annotations: options.annotations(for: day),
                holiday: options.holidaySchedule ? model.holidays.day(day) : nil,
                isInMonth: model.engine.calendar.isDate(day.date, equalTo: sectionMonth, toGranularity: .month),
                today: model.today, selection: model.selection, enabled: model.engine.isSupported(day.date)) {
                    [weak model] in model?.selectVisibleDay(day.date)
                }
        }
    }

    override func layout() {
        super.layout()
        let width = (bounds.width - 24) / 7
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 12 + CGFloat(index) * width, y: (bounds.height - 46) / 2, width: width, height: 46)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSRect(x: 12, y: bounds.height - 0.5, width: bounds.width - 24, height: 0.5).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

private final class CalendarDayButton: NSButton {
    private var day: DayInfo?
    private var annotation: Annotation?
    private var holiday: HolidayDay?
    private var today = false
    private var selected = false
    private var isInMonth = true
    private var onSelect: (() -> Void)?
    override var isFlipped: Bool { true }
    private static let accent = NSColor(srgbRed: 0.89, green: 0.20, blue: 0.15, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        target = self
        action = #selector(selectDay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(day: DayInfo, annotations: [Annotation], holiday: HolidayDay?,
                   isInMonth: Bool,
                   today: Date, selection: Date, enabled: Bool, onSelect: @escaping () -> Void) {
        self.day = day
        annotation = annotations.first
        self.holiday = holiday
        self.isInMonth = isInMonth
        self.today = day.date == today
        selected = day.date == selection
        isEnabled = enabled
        isHidden = !enabled
        self.onSelect = onSelect
        title = "\(day.year)年\(day.month)月\(day.day)日"
        var labels = [title, day.lunarFull] + annotations.map(\.title)
        if let holiday { labels.append(holiday.detail) }
        if self.today { labels.append("今天") }
        setAccessibilityLabel(labels.joined(separator: "，"))
        setAccessibilityValue(selected ? "已选中" : "")
        toolTip = labels.joined(separator: " · ")
        needsDisplay = true
    }

    @objc private func selectDay() { onSelect?() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let day, isEnabled else { return }
        let highlightedToday = today && isInMonth
        let muted = NSColor.labelColor.withAlphaComponent(0.30)
        if (selected && !highlightedToday) || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.09 : 0.06).setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            path.fill()
            if selected && !highlightedToday {
                NSColor.labelColor.withAlphaComponent(0.12).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        let circle = NSRect(x: bounds.midX - 13, y: 3, width: 26, height: 26)
        if highlightedToday { Self.accent.setFill(); NSBezierPath(ovalIn: circle).fill() }
        let weekend = day.weekday == 1 || day.weekday == 7
        drawText(String(day.day), rect: circle, font: .monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
                 color: !isInMonth ? muted : today ? .white : weekend ? .secondaryLabelColor : .labelColor)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color: NSColor = !isInMonth ? muted : annotation == nil ? .secondaryLabelColor : annotation?.kind == .solarTerm
            ? (dark ? NSColor(srgbRed: 0.48, green: 0.74, blue: 0.55, alpha: 1)
                    : NSColor(srgbRed: 0.17, green: 0.43, blue: 0.25, alpha: 1))
            : (dark ? NSColor(srgbRed: 1, green: 0.47, blue: 0.40, alpha: 1) : Self.accent)
        drawText(annotation?.shortTitle ?? day.lunarLabel,
                 rect: NSRect(x: 0, y: 31, width: bounds.width, height: 12),
                 font: .systemFont(ofSize: 10), color: color)
        if let holiday {
            drawText(holiday.badge, rect: NSRect(x: bounds.width - 9, y: 3, width: 9, height: 10),
                     font: .systemFont(ofSize: 8, weight: .medium),
                     color: !isInMonth ? muted : holiday.isOffDay ? Self.accent : .secondaryLabelColor)
        }
    }

    private func drawText(_ value: String, rect: NSRect, font: NSFont, color: NSColor) {
        let text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
}
