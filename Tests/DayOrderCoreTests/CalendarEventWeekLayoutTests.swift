import Foundation
import Testing
@testable import DayOrderCore

@Suite struct CalendarEventWeekLayoutTests {
    let engine = try! CalendarEngine()
    let zone = TimeZone(identifier: "Asia/Shanghai")!

    func event(_ id: String, from day: Int, to end: Int, title: String = "日程", allDay: Bool = true) -> CalendarEvent {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day))! }
        return CalendarEvent(id: id, title: title, start: date(day), end: date(end), allDay: allDay,
                             color: .init(red: 0.3, green: 0.4, blue: 0.8))
    }

    func layout(_ events: [CalendarEvent], first: Int) -> CalendarEventWeekLayout {
        let index = CalendarEventIndex(events: events,
            range: DateInterval(start: engine.date(2026, 9, 1), end: engine.date(2026, 11, 30)),
            timeZone: zone, engine: engine)
        return CalendarEventWeekLayout(dates: (0..<7).map { engine.date(2026, 10, first + $0) },
                                       days: index.days, engine: engine)
    }

    @Test func holidaySpansWeekAndEndsBeforeExclusiveMidnight() {
        let holiday = event("holiday", from: 1, to: 8, title: "国庆节（休）")
        let first = layout([holiday], first: -3).segments // 9 月 27 日起的一周
        #expect(first.count == 1)
        #expect(first.first?.columns == 4..<7)
        #expect(first.first?.continuesBefore == false)
        #expect(first.first?.continuesAfter == true)
        let second = layout([holiday], first: 4).segments
        #expect(second.first?.columns == 0..<4)
        #expect(second.first?.continuesBefore == true)
        #expect(second.first?.continuesAfter == false)
    }

    @Test func sameTitlesAndRecurringInstancesStaySeparate() {
        let first = event("repeat", from: 1, to: 2)
        let next = event("repeat", from: 2, to: 3)
        let other = event("other", from: 1, to: 2)
        let segments = layout([first, next, other], first: 1).segments
        #expect(segments.count == 3)
        #expect(Set(segments.map { $0.event.occurrenceID }).count == 3)
        #expect(segments.allSatisfy { $0.columns.count == 1 })
    }

    @Test func overlappingSpansKeepLanesAndReuseFreeSpace() {
        let long = event("long", from: 1, to: 8)
        let overlap = event("overlap", from: 3, to: 6)
        let single = event("single", from: 2, to: 3)
        let segments = layout([single, overlap, long], first: 1).segments
        #expect(segments.first { $0.event.id == "long" }?.lane == 0)
        #expect(segments.first { $0.event.id == "overlap" }?.lane == 1)
        #expect(segments.first { $0.event.id == "single" }?.lane == 1)
        for left in segments {
            for right in segments where left.event.id != right.event.id && left.columns.overlaps(right.columns) {
                #expect(left.lane != right.lane)
            }
        }
    }

    @Test func overflowNeverSplitsAVisibleSpan() {
        let first = event("first", from: 1, to: 8)
        let second = event("second", from: 1, to: 8)
        let third = event("third", from: 3, to: 4)
        let week = layout([third, second, first], first: 1)
        #expect(week.visibleSegments(limit: 2, reservingOverflow: true).map(\.event.id) == ["first"])
        #expect(week.visibleSegments(limit: 3).count == 3)
        #expect(week.visibleSegments(limit: 0).isEmpty)
        #expect(layout([], first: 1).segments.isEmpty)
    }

    @Test func weekStartAndMonthBoundaryDoNotChangeIdentity() {
        let value = event("month", from: 30, to: 34, allDay: false)
        for first in [25, 26] {
            let segment = layout([value], first: first).segments.first
            #expect(segment?.event.occurrenceID == value.occurrenceID)
            #expect(segment?.columns == (30 - first)..<7)
            #expect(segment?.continuesAfter == true)
        }
        let tail = layout([value], first: 32).segments.first
        #expect(tail?.columns == 0..<2)
        #expect(tail?.continuesBefore == true)
        #expect(tail?.continuesAfter == false)
    }
}
