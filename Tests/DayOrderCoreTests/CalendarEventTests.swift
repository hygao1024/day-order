import Foundation
import Testing
@testable import DayOrderCore

@Suite struct CalendarEventTests {
    let engine = try! CalendarEngine()
    let zone = TimeZone(identifier: "America/Los_Angeles")!

    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func event(_ id: String, _ start: String, _ end: String, allDay: Bool = false, title: String = "事件") -> CalendarEvent {
        CalendarEvent(id: id, title: title, start: date(start), end: date(end), allDay: allDay,
                      color: .init(red: 0.5, green: 0.2, blue: 0.8))
    }
    func index(_ events: [CalendarEvent]) -> CalendarEventIndex {
        CalendarEventIndex(events: events,
            range: DateInterval(start: date("2026-10-31T07:00:00Z"), end: date("2026-11-05T08:00:00Z")),
            timeZone: zone, engine: engine)
    }

    @Test func localDateIsIndependentOfLunarEngineTimeZone() {
        let event = event("local", "2026-11-01T06:30:00Z", "2026-11-01T06:45:00Z")
        let result = index([event])
        #expect(result.days[engine.date(2026, 10, 31)] == [event])
        #expect(result.days[engine.date(2026, 11, 1)] == nil)
    }

    @Test func midnightEndAndAllDayUseExclusiveEnd() {
        let overnight = event("night", "2026-11-01T05:00:00Z", "2026-11-01T07:00:00Z")
        let allDay = event("all", "2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z", allDay: true)
        let result = index([overnight, allDay])
        #expect(result.days[engine.date(2026, 10, 31)] == [overnight])
        #expect(result.days[engine.date(2026, 11, 1)] == [allDay])
        #expect(result.days[engine.date(2026, 11, 2)] == nil)
    }

    @Test func crossDaySurvivesDaylightSavingChange() {
        let value = event("dst", "2026-11-01T06:30:00Z", "2026-11-02T08:30:00Z")
        let result = index([value])
        #expect(result.days.count == 3)
        for day in [engine.date(2026, 10, 31), engine.date(2026, 11, 1), engine.date(2026, 11, 2)] {
            #expect(result.days[day] == [value])
        }
    }

    @Test func recurrenceDeduplicatesOccurrencesWithoutLosingDifferentDays() {
        let first = event("repeat", "2026-11-01T18:00:00Z", "2026-11-01T19:00:00Z")
        let second = event("repeat", "2026-11-02T18:00:00Z", "2026-11-02T19:00:00Z")
        let result = index([first, first, second])
        #expect(result.days[engine.date(2026, 11, 1)] == [first])
        #expect(result.days[engine.date(2026, 11, 2)] == [second])
    }

    @Test func invalidRangesAreRejectedAndLongEventsAreClipped() {
        let invalid = event("bad", "2026-11-02T18:00:00Z", "2026-11-01T18:00:00Z")
        let outside = event("outside", "2026-11-05T08:00:00Z", "2026-11-05T09:00:00Z")
        #expect(index([invalid, outside]).days.isEmpty)
        let long = event("long", "2020-01-01T00:00:00Z", "2030-01-01T00:00:00Z")
        #expect(index([long]).days.count == 5)
        let instant = event("instant", "2026-11-02T08:00:00Z", "2026-11-02T08:00:00Z")
        #expect(index([instant]).days[engine.date(2026, 11, 2)] == [instant])
    }

    @Test func allDayFirstAndBlankTitlesNormalize() {
        let timed = event("timed", "2026-11-01T18:00:00Z", "2026-11-01T19:00:00Z")
        let all = event("all", "2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z", allDay: true, title: " \n")
        #expect(index([timed, all]).days[engine.date(2026, 11, 1)] == [all, timed])
        #expect(all.title == "无标题日程")
    }
}
