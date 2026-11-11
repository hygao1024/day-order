import AppKit
import DayOrderCore
import QuartzCore
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
    // 外侧与内侧留白合计仍为 12 pt，保持日期列宽及星期栏对齐。
    static let cardInset: CGFloat = 6
    static let contentInset: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    @ObservedObject var model: CalendarModel
    @ObservedObject var events: SystemCalendarEvents
    let firstWeekday: Int
    let options: CalendarContentOptions
    let preferHighRefreshRate: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, firstWeekday: firstWeekday, options: options)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CalendarTimelineScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        // 原生子视图更新后也必须遵守卡片边界，不能仅依赖 SwiftUI 的裁剪。
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Self.cornerRadius
        scroll.layer?.cornerCurve = .continuous
        scroll.layer?.masksToBounds = true
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
        model.overviewFocusSource = context.coordinator
        scroll.onActivity = { [weak coordinator = context.coordinator] in coordinator?.beginInteraction() }
        scroll.onPause = { [weak coordinator = context.coordinator] in coordinator?.scheduleSnap() }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.liveScrollBegan),
            name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.liveScrollEnded),
            name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.windowOcclusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.preferHighRefreshRate = preferHighRefreshRate
        context.coordinator.update(firstWeekday: firstWeekday, options: options)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, CalendarOverviewFocusSource {
        let model: CalendarModel
        private(set) var timeline: CalendarTimeline
        weak var table: NSTableView?
        private var options: CalendarContentOptions
        private var revision: Int?
        private var today: Date
        private var selection: Date
        private var holidayRevision: Int
        private var eventRevision: Int
        private var eventMode: CalendarEventDisplay
        private var agenda: CalendarAgendaSelection?
        private var agendaHeight: CGFloat = 0
        private var agendaContentBottom: CGFloat = 46
        private var agendaRow: Int?
        private var agendaLayout: CalendarDayAgendaLayout?
        private var updating = false
        private var scrollTask: Task<Void, Never>?
        private var scrollSerial = 0
        private var days: [Date: [DayInfo]] = [:]
        private struct MonthSnap {
            let month: Date
            let weeks: Range<Int>
        }
        private var snapTask: Task<Void, Never>?
        private var snapSerial = 0
        private var animatingSnap = false
        private var navigating = false
        private var liveScrolling = false
        var preferHighRefreshRate = false
        private var snapDisplayLink: CADisplayLink?
        private var snapContinuation: CheckedContinuation<Void, Never>?
        #if DEBUG
        var heightQueries = 0
        var weekConfigurations = 0
        var hasActiveSnapDriver: Bool { snapDisplayLink != nil }
        var snapFrameRateRange: CAFrameRateRange? { snapDisplayLink?.preferredFrameRateRange }
        private(set) var snapFrameTimestamps: [Double] = []
        #endif

        init(model: CalendarModel, firstWeekday: Int, options: CalendarContentOptions) {
            self.model = model
            timeline = model.calendarTimeline(firstWeekday: firstWeekday)
            self.options = options
            today = model.today
            selection = model.selection
            holidayRevision = model.holidayRevision
            eventRevision = model.events.revision
            eventMode = model.events.mode
        }

        func disconnect() {
            if model.overviewFocusSource === self { model.overviewFocusSource = nil }
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
            let resized = eventMode != model.events.mode
            let requestedNavigation = revision != model.calendarScrollRevision
            let nextLayout = model.agendaLayout
            let nextAgenda = nextLayout == nil ? nil : model.agenda
            let nextHeight = nextLayout?.height ?? 0
            let agendaContentChanged = agendaLayout !== nextLayout
            agendaLayout = nextLayout
            let agendaSelectionChanged = agenda != nextAgenda
            var nextContentBottom = agendaContentBottom
            if agendaSelectionChanged || rebuilt || resized || eventRevision != model.events.revision {
                if let nextAgenda {
                    let nextTimeline = rebuilt ? model.calendarTimeline(firstWeekday: firstWeekday) : timeline
                    let row = nextTimeline.weekRow(containing: nextAgenda.date, inMonth: nextAgenda.month)
                    let start = nextTimeline.rows[row].date
                    let dates = (0..<7).map { model.engine.addingDays($0, to: start) }
                    nextContentBottom = CalendarWeekView.contentBottom(dates: dates, model: model)
                } else { nextContentBottom = 46 }
            }
            let agendaChanged = agendaSelectionChanged || agendaHeight != nextHeight
                || agendaContentBottom != nextContentBottom
            // 跨月查询会补回原日期详情并改变高度，不能因此取消正在执行的导航。
            let continuingNavigation = navigating && !requestedNavigation && !rebuilt && !resized
                && !agendaSelectionChanged
            let oldAgendaRow = agendaRow
            if (resized || agendaChanged) && !requestedNavigation { recordViewport() }
            agenda = nextAgenda
            agendaHeight = nextHeight
            agendaContentBottom = nextContentBottom
            let changed = self.options != options || today != model.today || selection != model.selection
                || holidayRevision != model.holidayRevision || eventRevision != model.events.revision || resized || agendaChanged || agendaContentChanged
            self.options = options
            today = model.today
            selection = model.selection
            holidayRevision = model.holidayRevision
            eventRevision = model.events.revision
            eventMode = model.events.mode
            if rebuilt {
                cancelSnap()
                timeline = model.calendarTimeline(firstWeekday: firstWeekday)
                agendaRow = agenda.map { timeline.weekRow(containing: $0.date, inMonth: $0.month) }
                days.removeAll()
                table.reloadData()
            } else if resized || agendaChanged {
                agendaRow = agenda.map { timeline.weekRow(containing: $0.date, inMonth: $0.month) }
                // 原生表格先同步落到真实端点；可见运动只由展示层的弹簧拥有。
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    let newAgendaRow = agendaRow
                    let changedRows = resized ? IndexSet(integersIn: 0..<timeline.rows.count)
                        : IndexSet([oldAgendaRow, newAgendaRow].compactMap { $0 })
                    table.noteHeightOfRows(withIndexesChanged: changedRows)
                    table.layoutSubtreeIfNeeded()
                }
            }
            if requestedNavigation || rebuilt || resized || (agendaChanged && !continuingNavigation) {
                cancelSnap()
                scrollSerial += 1
                scrollTask?.cancel()
                scrollTask = nil
                let restoring = (revision == nil || rebuilt || ((resized || agendaChanged) && !requestedNavigation)) ? model.calendarViewport : nil
                let restoredMonth = model.calendarSnappedMonth
                let animate = revision != nil && !rebuilt && !resized && !agendaChanged
                revision = model.calendarScrollRevision
                table.layoutSubtreeIfNeeded()
                if animate, let startingSelection = model.calendarScrollAnimationSelection,
                   let layout = monthLayout(for: model.calendarScrollTarget) {
                    navigating = true
                    animatingSnap = true
                    let serial = snapSerial
                    let requestedRevision = model.calendarScrollRevision
                    let target = model.calendarScrollTarget
                    let distance = abs(table.visibleRect.minY - table.rect(ofRow: layout.weeks.lowerBound).minY)
                    let monthNavigation = model.calendarMonthNavigationTarget != nil
                    let duration = distance < 0.5 ? 0 : monthNavigation ? 0.36 : min(0.70, 0.45 + distance / 6000)
                    snapTask = Task { [weak self] in
                        guard let self else { return }
                        defer {
                            if snapSerial == serial {
                                snapTask = nil
                                animatingSnap = false
                                navigating = false
                                model.finishCalendarScrollAnimation(revision: requestedRevision)
                            }
                        }
                        await animateMonth(layout, duration: duration, serial: serial,
                                           requestedRevision: requestedRevision, selectionOnArrival: target,
                                           startingSelection: startingSelection, easeOut: true)
                    }
                } else if let restoring, restoredMonth == nil || (agendaChanged && !resized) {
                    // 详情展开保留实际视口的小数偏移，不能因已标记吸附而重新贴齐月首。
                    moveViewport(to: table.rect(ofRow: timeline.weekRow(containing: restoring.date, inMonth: restoring.month)).minY + restoring.offset)
                } else {
                    let layout = monthLayout(for: restoredMonth ?? model.calendarScrollTarget)
                    model.calendarSnappedMonth = layout?.month
                    if let layout { moveViewport(to: table.rect(ofRow: layout.weeks.lowerBound).minY) }
                }
            }
            if changed || rebuilt {
                // 行高变化会移动已复用的周行；完成视口恢复后刷新最终可见行。
                table.layoutSubtreeIfNeeded()
                let range = table.rows(in: table.visibleRect)
                for row in range.location..<NSMaxRange(range) {
                    if let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? CalendarWeekView {
                        configure(view, row: row)
                    }
                }
            }
        }

        private func monthLayout(for date: Date) -> MonthSnap? {
            guard model.engine.isSupported(date) else { return nil }
            let month = model.engine.monthStart(date)
            guard let weeks = timeline.weekRows(inMonth: month) else { return nil }
            return MonthSnap(month: month, weeks: weeks)
        }

        private func cancelSnap() {
            if navigating, let revision { model.finishCalendarScrollAnimation(revision: revision) }
            snapSerial += 1
            snapTask?.cancel()
            snapTask = nil
            stopSnapFrames()
            animatingSnap = false
            navigating = false
        }

        private func moveViewport(to y: CGFloat) {
            guard let table, let scroll = table.enclosingScrollView else { return }
            let limit = max(0, table.bounds.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: table.convert(NSPoint(x: 0, y: min(max(0, y), limit)), to: scroll.contentView))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func beginInteraction() {
            cancelSnap()
            if model.calendarScrollAnimationSelection != nil {
                revision = model.calendarScrollRevision
                model.finishCalendarScrollAnimation(revision: model.calendarScrollRevision)
            }
            model.calendarSnappedMonth = nil
            recordViewport()
        }

        @objc func liveScrollBegan() {
            liveScrolling = true
            beginInteraction()
        }

        @objc func liveScrollEnded() {
            liveScrolling = false
            scheduleSnap()
        }

        @objc func windowOcclusionChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === table?.window,
                  !window.occlusionState.contains(.visible) else { return }
            // 不可见视图可能不再收到刷新回调，不能依赖下一帧释放等待任务。
            cancelSnap()
        }

        private func stopSnapFrames() {
            snapDisplayLink?.invalidate()
            snapDisplayLink = nil
            let continuation = snapContinuation
            snapContinuation = nil
            continuation?.resume()
        }

        func scheduleSnap() {
            guard !navigating else { return }
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
                model.calendarSnappedMonth = candidate.month
                model.browseMonth(containing: candidate.month)
                await animateMonth(candidate, duration: 0.20, serial: serial, requestedRevision: requestedRevision)
            }
        }

        private func animateMonth(_ candidate: MonthSnap, duration: Double, serial: Int,
                                  requestedRevision: Int, selectionOnArrival: Date? = nil,
                                  startingSelection: Date? = nil, easeOut: Bool = false) async {
            guard let table else { return }
            let first = candidate.weeks.lowerBound
            let offset = table.visibleRect.minY - table.rect(ofRow: first).minY
            let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            let start = CACurrentMediaTime()
            func canContinue() -> Bool {
                snapSerial == serial && requestedRevision == model.calendarScrollRevision
                    && (startingSelection == nil || model.selection == startingSelection)
                    && !model.showingSettings && !model.showingYearOverview
                    && table.window?.isVisible == true
            }
            guard !Task.isCancelled, canContinue() else { return }
            #if DEBUG
            snapFrameTimestamps = []
            #endif
            if duration == 0 {
                moveViewport(to: table.rect(ofRow: first).minY)
            } else {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        guard !Task.isCancelled, canContinue() else { continuation.resume(); return }
                        snapContinuation = continuation
                        let target = CalendarDisplayLinkTarget { [weak self] link in
                            guard let self, snapDisplayLink === link else { link.invalidate(); return }
                            guard canContinue() else { stopSnapFrames(); return }
                            CalendarRefreshPolicy.apply(to: link, in: table, enabled: preferHighRefreshRate)
                            #if DEBUG
                            snapFrameTimestamps.append(link.targetTimestamp)
                            #endif
                            let progress = min(1, max(0, (link.targetTimestamp - start) / duration))
                            let remaining = easeOut ? pow(1 - progress, 3) : 1 - progress * progress * (3 - 2 * progress)
                            moveViewport(to: table.rect(ofRow: first).minY + offset * remaining)
                            if selectionOnArrival != nil { recordViewport() }
                            if progress == 1 { stopSnapFrames() }
                        }
                        let link = table.displayLink(target: target, selector: #selector(CalendarDisplayLinkTarget.tick(_:)))
                        CalendarRefreshPolicy.apply(to: link, in: table, enabled: preferHighRefreshRate)
                        snapDisplayLink = link
                        link.add(to: .main, forMode: .common)
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in
                        guard let self, snapSerial == serial else { return }
                        stopSnapFrames()
                    }
                }
            }
            guard !Task.isCancelled, canContinue() else { return }
            model.calendarSnappedMonth = candidate.month
            model.calendarViewport = (timeline.rows[first].date, candidate.month, 0)
            model.browseMonth(containing: candidate.month)
            if let selectionOnArrival { model.selectVisibleDay(selectionOnArrival) }
        }

        private func recordViewport() {
            guard let table else { return }
            let row = table.row(at: NSPoint(x: 1, y: table.visibleRect.minY + 1))
            guard timeline.rows.indices.contains(row) else { return }
            let item = timeline.rows[row]
            let weekRow = timeline.weekRow(containing: item.date, inMonth: item.sectionMonth)
            model.calendarViewport = (item.date, item.sectionMonth,
                                      table.visibleRect.minY - table.rect(ofRow: weekRow).minY)
            model.browseMonth(containing: model.calendarSnappedMonth ?? item.sectionMonth)
        }

        func prepareOverviewFocus() -> Date? {
            guard let table, table.enclosingScrollView != nil else { return nil }
            cancelSnap()
            // 点击时读取实际视口，不能等待异步滚动通知，也不能让待执行的吸附改变起点。
            recordViewport()
            let visible = table.visibleRect
            let range = table.rows(in: visible)
            var areas: [Date: CGFloat] = [:]
            for row in range.location..<NSMaxRange(range) where timeline.rows.indices.contains(row) {
                let intersection = table.rect(ofRow: row).intersection(visible)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                // 标题和补位周属于其月份区块，不重复计入相邻月份。
                areas[timeline.rows[row].sectionMonth, default: 0] += intersection.width * intersection.height
            }
            return areas.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
            }?.key
        }

        private func nearbyMonth() -> MonthSnap? {
            guard let table else { return nil }
            let top = table.visibleRect.minY
            let row = table.row(at: NSPoint(x: 1, y: top))
            guard timeline.rows.indices.contains(row),
                  let current = monthLayout(for: timeline.rows[row].sectionMonth) else { return nil }
            // 月标题和前两周属于同一吸附区间，第三周起点不包含在内。
            if row < current.weeks.lowerBound + 2 { return current }

            // 尚未进入下个月时，保留月初接近顶部的吸附距离。
            let nextRow = current.weeks.upperBound
            guard timeline.rows.indices.contains(nextRow),
                  let next = monthLayout(for: timeline.rows[nextRow].sectionMonth),
                  table.rect(ofRow: next.weeks.lowerBound).minY - top <= 44 else { return nil }
            return next
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
                recordViewport()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { timeline.rows.count }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            #if DEBUG
            heightQueries += 1
            #endif
            switch timeline.rows[row] {
            case .month: return 30
            case .week:
                let base = baseWeekHeight(row, in: tableView)
                guard agendaRow == row else { return base }
                let dateTop = (base - 46 - eventMode.extraRowHeight) / 2
                return dateTop + agendaContentBottom + 4 + agendaHeight
            }
        }
        private func baseWeekHeight(_ row: Int, in tableView: NSTableView) -> CGFloat {
            let weeks = timeline.weekRows(inMonth: timeline.rows[row].sectionMonth)!
            let scale = tableView.window?.backingScaleFactor ?? 2
            let unit = eventMode.viewportHeight * scale / CGFloat(weeks.count)
            let index = CGFloat(row - weeks.lowerBound)
            return (floor((index + 1) * unit) - floor(index * unit)) / scale
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

        func refreshEvents(in view: CalendarWeekView, row: Int) {
            configure(view, row: row)
        }

        private func configure(_ view: CalendarWeekView, row: Int) {
            #if DEBUG
            weekConfigurations += 1
            #endif
            guard case .week(let start, let sectionMonth) = timeline.rows[row] else { return }
            let values: [DayInfo]
            if let cached = days[start] { values = cached }
            else {
                values = (0..<7).map { model.engine.info(for: model.engine.addingDays($0, to: start)) }
                // 缓存有界且属于当前滚动视图，长距离浏览不积累整部历法。
                if days.count >= 128 { days.removeAll(keepingCapacity: true) }
                days[start] = values
            }
            view.configure(days: values, sectionMonth: sectionMonth, model: model, options: options,
                           baseHeight: baseWeekHeight(row, in: table!), contentBottom: agendaContentBottom)
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
        let inset = CalendarTimelineView.contentInset
        label.frame = NSRect(x: inset, y: 6, width: bounds.width - 2 * inset, height: 20)
    }
}

final class CalendarWeekView: NSView {
    private let buttons = (0..<7).map { _ in CalendarDayButton(frame: .zero) }
    let agendaView = CalendarDayAgendaView(frame: .zero)
    private var agendaHeight: CGFloat = 0
    private var baseHeight: CGFloat = 0
    private var contentBottom: CGFloat = 46
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        buttons.forEach(addSubview)
        addSubview(agendaView)
        agendaView.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 与实际标记共用绘制几何，跨日分行和溢出计数也参与整周占用高度。
    static func contentBottom(dates: [Date], model: CalendarModel) -> CGFloat {
        let mode = model.events.mode
        let layout = CalendarEventWeekLayout(dates: dates, days: model.events.days, engine: model.engine)
        let visible = layout.visibleSegments(limit: mode == .detailed ? 2 : 3, reservingOverflow: mode == .detailed)
        return dates.enumerated().reduce(CGFloat(46)) { bottom, pair in
            let (column, date) = pair
            let segments = visible.filter { $0.columns.contains(column) }
            let overflow = layout.segments.filter { $0.columns.contains(column) }.count - segments.count
            let markers = CalendarEventDrawing.markers(events: model.events.days[date] ?? [], mode: mode,
                width: 40, muted: false, dark: false, segments: segments, column: column, overflow: overflow)
            return max(bottom, markers.map { $0.style.frame.maxY }.max() ?? 0)
        }
    }

    func configure(days: [DayInfo], sectionMonth: Date, model: CalendarModel, options: CalendarContentOptions,
                   baseHeight: CGFloat, contentBottom: CGFloat) {
        self.baseHeight = baseHeight
        self.contentBottom = contentBottom
        let mode = model.events.mode
        if let agenda = model.agenda, agenda.month == sectionMonth,
           days.contains(where: { $0.date == agenda.date }), let value = model.agendaLayout {
            agendaHeight = value.height
            agendaView.isHidden = false
            agendaView.configure(selection: agenda, layout: value, engine: model.engine)
        } else {
            agendaHeight = 0
            agendaView.isHidden = true
            agendaView.clear()
        }
        let layout = CalendarEventWeekLayout(dates: days.map(\.date), days: model.events.days, engine: model.engine)
        let visible = layout.visibleSegments(limit: mode == .detailed ? 2 : 3, reservingOverflow: mode == .detailed)
        for (column, pair) in zip(buttons, days).enumerated() {
            let (button, day) = pair
            let segments = visible.filter { $0.columns.contains(column) }
            let overflow = layout.segments.filter { $0.columns.contains(column) }.count - segments.count
            button.configure(day: day, annotations: options.annotations(for: day),
                holiday: options.holidaySchedule ? model.holidays.day(day) : nil,
                isInMonth: model.engine.calendar.isDate(day.date, equalTo: sectionMonth, toGranularity: .month),
                events: model.events.days[day.date] ?? [], mode: mode,
                segments: segments, column: column, overflow: overflow,
                today: model.today, selection: model.selection, enabled: model.engine.isSupported(day.date)) {
                    [weak model] in model?.activateVisibleDay(day.date, in: sectionMonth)
                }
            button.setAccessibilityHelp(mode == .hidden ? nil : model.agenda?.date == day.date
                ? "再次点击收起当天日程" : "选中后再次点击展开当天日程")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = CalendarTimelineView.contentInset
        let width = (bounds.width - 2 * inset) / 7
        for (index, button) in buttons.enumerated() {
            let height = 46 + button.eventMode.extraRowHeight
            // 展开时裁去日期格底部空白，避免动画快照把详情重复裁入日期底图。
            button.frame = NSRect(x: inset + CGFloat(index) * width, y: (baseHeight - height) / 2,
                                  width: width, height: agendaView.isHidden ? height : contentBottom)
        }
        agendaView.frame = NSRect(x: inset, y: bounds.height - agendaHeight, width: bounds.width - 2 * inset, height: agendaHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        let inset = CalendarTimelineView.contentInset
        NSRect(x: inset, y: bounds.height - 0.5, width: bounds.width - 2 * inset, height: 0.5).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class CalendarDayButton: NSButton, CalendarZoomParticipant {
    var zoomHiddenDays: Set<Int> = []
    var snapshotHidesEventMarkers = false
    private var day: DayInfo?
    private var annotation: Annotation?
    private var holiday: HolidayDay?
    private var today = false
    private var selected = false
    private var isInMonth = true
    private var onSelect: (() -> Void)?
    private(set) var events: [CalendarEvent] = []
    private(set) var eventMode = CalendarEventDisplay.hidden
    private var eventSegments: [CalendarEventWeekLayout.Segment] = []
    private var eventColumn = 0
    private var eventOverflow = 0
    var date: Date? { day?.date }
    var eventMarkers: [CalendarEventMarker] {
        CalendarEventDrawing.markers(events: events, mode: eventMode, width: bounds.width,
            muted: !isInMonth, dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            segments: eventSegments, column: eventColumn, overflow: eventOverflow)
    }
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
                   events: [CalendarEvent], mode: CalendarEventDisplay,
                   segments: [CalendarEventWeekLayout.Segment], column: Int, overflow: Int,
                   today: Date, selection: Date, enabled: Bool, onSelect: @escaping () -> Void) {
        self.day = day
        annotation = annotations.first
        self.holiday = holiday
        self.isInMonth = isInMonth
        self.events = events
        eventMode = mode
        eventSegments = segments
        eventColumn = column
        eventOverflow = overflow
        self.today = day.date == today
        selected = day.date == selection
        isEnabled = enabled
        isHidden = !enabled
        self.onSelect = onSelect
        title = "\(day.year)年\(day.month)月\(day.day)日"
        var labels = [title, day.lunarFull] + annotations.map(\.title)
        if let holiday { labels.append(holiday.detail) }
        if self.today { labels.append("今天") }
        if mode != .hidden, !events.isEmpty {
            labels.append("\(events.count)项日程")
            labels += events.map(\.title)
        }
        setAccessibilityLabel(labels.joined(separator: "，"))
        setAccessibilityValue(selected ? "已选中" : "")
        needsDisplay = true
        superview?.needsLayout = true
    }

    @objc private func selectDay() { onSelect?() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let day, isEnabled else { return }
        let highlightedToday = today && isInMonth
        let muted = CalendarSurface.adjacentTextColor
        if (selected && !highlightedToday) || isHighlighted {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.09 : 0.06).setFill()
            feedbackPath.fill()
        }
        let circle = dayNumberFrame
        if !zoomHiddenDays.contains(day.day) {
            if highlightedToday { Self.accent.setFill(); NSBezierPath(ovalIn: circle).fill() }
            drawText(String(day.day), rect: circle, font: .monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
                     color: !isInMonth ? muted : today ? .white : .labelColor)
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color: NSColor = !isInMonth ? muted : annotation == nil ? CalendarSurface.secondaryTextColor : annotation?.kind == .solarTerm
            ? (dark ? NSColor(srgbRed: 0.48, green: 0.74, blue: 0.55, alpha: 1)
                    : NSColor(srgbRed: 0.17, green: 0.43, blue: 0.25, alpha: 1))
            : (dark ? NSColor(srgbRed: 1, green: 0.47, blue: 0.40, alpha: 1) : Self.accent)
        drawText(annotation?.shortTitle ?? day.lunarLabel,
                 rect: NSRect(x: 0, y: 31, width: bounds.width, height: 12),
                 font: .systemFont(ofSize: 10), color: color)
        if let holiday {
            drawText(holiday.badge, rect: NSRect(x: bounds.width - 9, y: 3, width: 9, height: 10),
                     font: .systemFont(ofSize: 8, weight: .medium),
                     color: !isInMonth ? muted : holiday.isOffDay ? Self.accent : CalendarSurface.secondaryTextColor)
        }
        if !snapshotHidesEventMarkers, eventMode != .hidden, !events.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(rect: bounds).addClip()
            for marker in eventMarkers {
                CalendarEventDrawing.draw(marker: marker, style: marker.style, dark: dark)
            }
        }
    }

    func zoomAnchors(month: Int, in root: NSView) -> [CalendarZoomAnchor] {
        guard let day, day.year * 100 + day.month == month, isInMonth, isEnabled else { return [] }
        let circle = dayNumberFrame
        guard let scroll = enclosingScrollView,
              root.convert(scroll.bounds, from: scroll).intersects(root.convert(circle, from: self)) else { return [] }
        return [CalendarZoomAnchor(day: day.day, frame: root.convert(circle, from: self),
            fontSize: 16, weight: NSFont.Weight.semibold.rawValue,
            color: today ? .white : .labelColor, circle: today)]
    }

    private var dayNumberFrame: NSRect { NSRect(x: bounds.midX - 13, y: 3, width: 26, height: 26) }

    private var feedbackPath: NSBezierPath {
        NSBezierPath(cgPath: RoundedRectangle(cornerRadius: 9, style: .continuous)
            .path(in: focusRingMaskBounds).cgPath)
    }

    private func drawText(_ value: String, rect: NSRect, font: NSFont, color: NSColor) {
        let text = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override var focusRingMaskBounds: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: 46).insetBy(dx: 0.5, dy: 0.5)
    }
    override func drawFocusRingMask() { feedbackPath.fill() }
}
