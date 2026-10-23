import DayOrderCore
import Foundation
import SwiftUI

@MainActor
final class CalendarModel: ObservableObject {
    let engine: CalendarEngine
    @Published var today: Date
    @Published var selection: Date
    @Published var month: Date
    @Published var showingSettings = false
    @Published var showingYearOverview = false
    @Published var yearDraft = ""
    @Published var showingYearEntry = false
    @Published private(set) var overviewTarget = CalendarEngine.years.lowerBound * 100 + 1
    @Published private(set) var overviewScrollRevision = 0
    @Published var holidays = HolidaySchedule()
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
                holidays.years[target] = cached
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

    init(engine: CalendarEngine, now: Date = Date(), holidayCacheDirectory: URL? = nil) {
        let directory = holidayCacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DayOrder/holidays", isDirectory: true)
        holidayRepository = HolidayRepository(cacheDirectory: directory)
        self.engine = engine
        let currentDay = engine.today(now: now)
        let selectedDay = engine.clamped(currentDay)
        today = currentDay
        selection = selectedDay
        month = engine.monthStart(selectedDay)
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
        selection = date
        month = engine.monthStart(date)
        showingYearOverview = false
        showingYearEntry = false
    }

    func openYearOverview() {
        let parts = engine.calendar.dateComponents([.year, .month], from: month)
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

    func goToToday() {
        select(engine.clamped(today))
    }

    func canMoveMonth(_ amount: Int) -> Bool {
        engine.isSupported(engine.addingMonths(amount, to: month))
    }

    func moveMonth(_ amount: Int) {
        guard canMoveMonth(amount) else { return }
        select(engine.addingMonths(amount, to: selection))
    }

    func moveDay(_ amount: Int) {
        select(engine.addingDays(amount, to: selection))
    }
}
