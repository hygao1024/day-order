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
