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
    @Published var showingMonthPicker = false
    @Published var monthPickerYear = ""

    var validMonthPickerYear: Int? {
        guard let year = Int(monthPickerYear.trimmingCharacters(in: .whitespaces)),
              CalendarEngine.years.contains(year) else { return nil }
        return year
    }

    init(engine: CalendarEngine, now: Date = Date()) {
        self.engine = engine
        let currentDay = engine.today(now: now)
        let selectedDay = engine.clamped(currentDay)
        today = currentDay
        selection = selectedDay
        month = engine.monthStart(selectedDay)
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
        showingMonthPicker = false
    }

    func openMonthPicker() {
        monthPickerYear = String(engine.calendar.component(.year, from: month))
        showingMonthPicker = true
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
