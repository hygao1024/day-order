import Foundation
import Testing
@testable import DayOrderCore

@Suite struct CalendarTimelineTests {
    let engine = try! CalendarEngine()

    @Test(arguments: [1, 2]) func everyPrimaryDateOccursOnce(firstWeekday: Int) {
        let timeline = CalendarTimeline(engine: engine, firstWeekday: firstWeekday)
        var previous: Date?
        var count = 0
        var months: [Date] = []
        for (index, row) in timeline.rows.enumerated() {
            switch row {
            case .month(let date): months.append(date)
            case .week(let start, let sectionMonth):
                let weeks = timeline.weekRows(inMonth: sectionMonth)!
                #expect(weeks.contains(index))
                #expect((4...6).contains(weeks.count))
                #expect(timeline.rows[weeks.lowerBound - 1].date == sectionMonth)
                #expect(timeline.rows[weeks.upperBound - 1].sectionMonth == sectionMonth)
                #expect(engine.calendar.component(.weekday, from: start) == firstWeekday)
                for day in 0..<7 {
                    let date = engine.addingDays(day, to: start)
                    #expect(timeline.weekRow(containing: date, inMonth: sectionMonth) == index)
                    guard engine.isSupported(date), engine.monthStart(date) == sectionMonth else { continue }
                    if let previous { #expect(date == engine.addingDays(1, to: previous)) }
                    #expect(timeline.weekRow(containing: date) == index)
                    previous = date
                    count += 1
                }
            }
        }
        let first = engine.date(1901, 1, 1)
        let last = engine.date(2100, 12, 31)
        #expect(count == engine.calendar.dateComponents([.day], from: first, to: last).day! + 1)
        #expect(previous == last)
        #expect(months.count == 2400)
        #expect(months.first == first)
        #expect(months.last == engine.date(2100, 12, 1))
        for pair in zip(months, months.dropFirst()) {
            #expect(pair.1 == engine.addingMonths(1, to: pair.0))
        }
    }

    @Test func boundaryWeeksBelongToTheirOwnMonthSections() {
        let timeline = CalendarTimeline(engine: engine, firstWeekday: 2)
        let october = engine.date(2026, 10, 1)
        let november = engine.date(2026, 11, 1)
        let octoberEnd = timeline.weekRow(containing: engine.date(2026, 10, 31))
        let novemberStart = timeline.weekRow(containing: november)
        #expect(novemberStart == octoberEnd + 2)
        #expect(timeline.rows[octoberEnd].date == timeline.rows[novemberStart].date)
        #expect(timeline.rows[octoberEnd].sectionMonth == october)
        #expect(timeline.rows[novemberStart].sectionMonth == november)
        #expect(timeline.weekRow(containing: november, inMonth: october) == octoberEnd)
        #expect(timeline.weekRow(containing: engine.date(2026, 10, 31), inMonth: november) == novemberStart)
        let leapDay = engine.date(2028, 2, 29)
        #expect(timeline.weekRows(inMonth: leapDay) == nil)
        #expect(timeline.weekRows(inMonth: engine.date(1900, 1, 1)) == nil)
        #expect(timeline.rows[timeline.weekRow(containing: leapDay)].sectionMonth == engine.date(2028, 2, 1))
        #expect(timeline.rows[timeline.weekRow(containing: engine.date(2028, 3, 1))].sectionMonth == engine.date(2028, 3, 1))
        #expect(timeline.weekRow(containing: engine.date(1900, 1, 1)) == timeline.weekRow(containing: engine.date(1901, 1, 1)))
        #expect(timeline.weekRow(containing: engine.date(2101, 1, 1)) == timeline.weekRow(containing: engine.date(2100, 12, 31)))
    }
}
