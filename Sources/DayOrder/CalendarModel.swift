import DayOrderCore
import Foundation
import SwiftUI

@MainActor
protocol CalendarOverviewFocusSource: AnyObject {
    func prepareOverviewFocus() -> Date?
}

@MainActor
final class CalendarModel: ObservableObject {
    let engine: CalendarEngine
    let events: SystemCalendarEvents
    // 只缓存当前星期起始方式的不可变行索引；页面生命周期仍由各自的视图拥有。
    private var timelineIndex: CalendarTimeline?
    #if DEBUG
    var timelineBuildMilliseconds = 0.0
    #endif

    func calendarTimeline(firstWeekday: Int) -> CalendarTimeline {
        let weekday = firstWeekday == 1 ? 1 : 2
        if let timelineIndex, timelineIndex.firstWeekday == weekday { return timelineIndex }
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        #endif
        let index = CalendarTimeline(engine: engine, firstWeekday: weekday)
        timelineIndex = index
        #if DEBUG
        timelineBuildMilliseconds += (ProcessInfo.processInfo.systemUptime - began) * 1000
        #endif
        return index
    }
    @Published var today: Date
    @Published var selection: Date
    @Published var month: Date
    @Published private(set) var calendarScrollRevision = 0
    private(set) var calendarScrollTarget: Date
    // 非空表示动画请求，并记录请求时的选择以识别启动前的取消。
    private(set) var calendarScrollAnimationSelection: Date?
    private(set) var calendarMonthNavigationTarget: Date?
    var calendarViewport: (date: Date, month: Date, offset: CGFloat)?
    var calendarSnappedMonth: Date?
    weak var overviewFocusSource: (any CalendarOverviewFocusSource)?
    private(set) var overviewFocusMonth: Date?
    @Published var showingSettings = false
    @Published var showingYearOverview = false
    @Published var yearDraft = ""
    @Published var showingYearEntry = false
    @Published private(set) var overviewTarget = CalendarEngine.years.lowerBound * 100 + 1
    @Published private(set) var overviewScrollRevision = 0
    @Published var holidays = HolidaySchedule()
    @Published private(set) var holidayRevision = 0
    @Published var holidayUpdatingYear: Int?
    @Published var holidayUpdateMessages: [Int: String] = [:]
    private let holidayRepository: HolidayRepository
    private var holidayUpdateTask: Task<Void, Never>?
    private var holidayRevisions: [Int: Int] = [:]

    var displayedYear: Int { engine.calendar.component(.year, from: month) }

    func loadHolidayCache(year: Int) async {
        for target in (year - 1)...(year + 1) where HolidayYear.supportedYears.contains(target) {
            let revision = holidayRevisions[target, default: 0]
            let cached = await holidayRepository.cached(year: target)
            guard !Task.isCancelled else { return }
            // 只排除同年度更新前的旧读取，其他年度仍可加载缓存。
            if let cached, holidayRevisions[target, default: 0] == revision {
                if holidays.years[target]?.days != cached.days {
                    holidays.years[target] = cached
                    holidayRevision += 1
                }
            }
        }
    }

    func updateHolidays(year: Int) {
        guard holidayUpdateTask == nil else { return }
        holidayUpdatingYear = year
        holidayUpdateMessages[year] = "正在更新放假安排…"
        holidayUpdateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                holidayUpdatingYear = nil
                holidayUpdateTask = nil
            }
            var messages: [String] = []
            for target in [year, year + 1] {
                do {
                    let document = try await holidayRepository.update(year: target)
                    try Task.checkCancellation()
                    holidayRevisions[target, default: 0] += 1
                    holidays.years[target] = document
                    holidayRevision += 1
                    messages.append("\(target)年已更新")
                } catch {
                    if Task.isCancelled { return }
                    let retained = holidays.years[target] == nil ? "" : "，保留原数据"
                    messages.append("\(target)年：\(error.localizedDescription)\(retained)")
                }
            }
            holidayUpdateMessages[year] = messages.joined(separator: "；")
        }
    }

    func cancelHolidayUpdate() {
        holidayUpdateTask?.cancel()
    }

    var validYearDraft: Int? {
        guard let year = Int(yearDraft.trimmingCharacters(in: .whitespaces)),
              CalendarEngine.years.contains(year) else { return nil }
        return year
    }

    init(engine: CalendarEngine, now: Date = Date(), holidayCacheDirectory: URL? = nil,
         events: SystemCalendarEvents = SystemCalendarEvents()) {
        self.events = events
        let directory = holidayCacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayOrder/holidays", isDirectory: true)
        holidayRepository = HolidayRepository(cacheDirectory: directory)
        self.engine = engine
        let currentDay = engine.today(now: now)
        let selectedDay = engine.clamped(currentDay)
        today = currentDay
        selection = selectedDay
        month = engine.monthStart(selectedDay)
        calendarScrollTarget = selectedDay
        holidays = HolidaySchedule(years: (try? HolidayYear.bundled()) ?? [:])
    }

    func refreshToday() {
        let newToday = engine.today()
        if newToday != today {
            let followingToday = selection == today
            today = newToday
            if followingToday { goToToday() }
        }
    }

    func select(_ date: Date) {
        guard engine.isSupported(date) else { return }
        overviewFocusMonth = nil
        selection = date
        month = engine.monthStart(date)
        calendarScrollTarget = date
        calendarScrollAnimationSelection = nil
        calendarMonthNavigationTarget = nil
        calendarViewport = nil
        calendarSnappedMonth = nil
        calendarScrollRevision += 1
        showingYearOverview = false
        showingYearEntry = false
    }

    func selectVisibleDay(_ date: Date) {
        guard engine.isSupported(date) else { return }
        selection = date
    }

    func browseMonth(containing date: Date) {
        let visibleMonth = engine.monthStart(engine.clamped(date))
        if month != visibleMonth { month = visibleMonth }
    }

    func openYearOverview() {
        let focus = overviewFocusSource?.prepareOverviewFocus() ?? overviewFocusMonth ?? month
        overviewFocusMonth = focus
        let parts = engine.calendar.dateComponents([.year, .month], from: focus)
        yearDraft = String(parts.year!)
        overviewTarget = parts.year! * 100 + ((parts.month! - 1) / 2 * 2 + 1)
        overviewScrollRevision += 1
        showingYearEntry = false
        showingYearOverview = true
    }

    func editOverviewYear(_ year: Int) {
        yearDraft = String(year)
        showingYearEntry = true
    }

    func jumpToOverviewYear() {
        guard let year = validYearDraft else { return }
        overviewTarget = year * 100 + 1
        overviewScrollRevision += 1
        showingYearEntry = false
    }

    func dismissYearLevel() {
        if showingYearEntry { showingYearEntry = false }
        else { showingYearOverview = false }
    }

    func jumpToMonth(_ targetMonth: Int, year: Int) {
        guard CalendarEngine.years.contains(year), (1...12).contains(targetMonth) else { return }
        let start = engine.date(year, targetMonth, 1)
        guard let days = engine.calendar.range(of: .day, in: .month, for: start) else { return }
        let day = min(engine.calendar.component(.day, from: selection), days.count)
        select(engine.date(year, targetMonth, day))
    }

    func goToToday(animated: Bool = false) {
        let target = engine.clamped(today)
        guard animated, !showingSettings, !showingYearOverview else {
            select(target)
            return
        }
        // 选择与详情在到达后更新；保留当前浏览位置供动画及中断恢复使用。
        calendarScrollTarget = target
        calendarScrollAnimationSelection = selection
        calendarMonthNavigationTarget = nil
        calendarSnappedMonth = nil
        calendarScrollRevision += 1
    }

    func canMoveMonth(_ amount: Int) -> Bool {
        engine.isSupported(engine.addingMonths(amount, to: calendarMonthNavigationTarget ?? month))
    }

    func moveMonth(_ amount: Int, animated: Bool = false) {
        guard canMoveMonth(amount) else { return }
        let target = engine.addingMonths(amount, to: calendarMonthNavigationTarget ?? month)
        let parts = engine.calendar.dateComponents([.year, .month], from: target)
        guard animated, !showingSettings, !showingYearOverview,
              let days = engine.calendar.range(of: .day, in: .month, for: target) else {
            jumpToMonth(parts.month!, year: parts.year!)
            return
        }
        let day = min(engine.calendar.component(.day, from: selection), days.count)
        selection = engine.date(parts.year!, parts.month!, day)
        overviewFocusMonth = nil
        calendarScrollTarget = selection
        calendarScrollAnimationSelection = selection
        // 连点以已请求月份累计，不能被动画途中可见的旧月份覆盖。
        calendarMonthNavigationTarget = engine.monthStart(target)
        calendarSnappedMonth = nil
        calendarScrollRevision += 1
    }

    func finishCalendarScrollAnimation(revision: Int) {
        guard revision == calendarScrollRevision else { return }
        calendarScrollAnimationSelection = nil
        calendarMonthNavigationTarget = nil
    }

    func moveDay(_ amount: Int) {
        select(engine.addingDays(amount, to: selection))
    }
}
