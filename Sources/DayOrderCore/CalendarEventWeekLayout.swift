import Foundation

public struct CalendarEventWeekLayout {
    public struct Segment {
        public let event: CalendarEvent
        public let columns: Range<Int>
        public fileprivate(set) var lane: Int
        public let continuesBefore: Bool
        public let continuesAfter: Bool
    }

    public let segments: [Segment]

    /// dates 为同周的连续日期键，days 来自 CalendarEventIndex。
    /// 复用索引归属，避免在布局层重新解释时区和排他结束。
    public init(dates: [Date], days: [Date: [CalendarEvent]], engine: CalendarEngine) {
        var occurrences: [CalendarEvent.OccurrenceID: (CalendarEvent, [Int])] = [:]
        for (column, date) in dates.enumerated() {
            for event in days[date] ?? [] {
                if occurrences[event.occurrenceID] == nil { occurrences[event.occurrenceID] = (event, []) }
                occurrences[event.occurrenceID]!.1.append(column)
            }
        }
        var candidates = occurrences.values.map { event, columns in
            let first = columns.min()!
            let last = columns.max()!
            func contains(_ date: Date) -> Bool {
                days[date]?.contains { $0.occurrenceID == event.occurrenceID } == true
            }
            return Segment(event: event, columns: first..<(last + 1), lane: 0,
                continuesBefore: first == 0 && contains(engine.addingDays(-1, to: dates[first])),
                continuesAfter: last == dates.count - 1 && contains(engine.addingDays(1, to: dates[last])))
        }
        candidates.sort {
            let leftSpans = $0.columns.count > 1 || $0.continuesBefore || $0.continuesAfter
            let rightSpans = $1.columns.count > 1 || $1.continuesBefore || $1.continuesAfter
            if leftSpans != rightSpans { return leftSpans }
            if $0.event.allDay != $1.event.allDay { return $0.event.allDay }
            if $0.event.start != $1.event.start { return $0.event.start < $1.event.start }
            if $0.event.title != $1.event.title { return $0.event.title < $1.event.title }
            return $0.event.id < $1.event.id
        }
        var occupied: [Set<Int>] = []
        for index in candidates.indices {
            let columns = Set(candidates[index].columns)
            let lane = occupied.firstIndex { $0.isDisjoint(with: columns) } ?? occupied.count
            if lane == occupied.count { occupied.append([]) }
            occupied[lane].formUnion(columns)
            candidates[index].lane = lane
        }
        segments = candidates
    }

    // 计数占用末行时整段让位，不能只在拥挤的某一天切断跨日横条。
    public func visibleSegments(limit: Int, reservingOverflow: Bool = false) -> [Segment] {
        let crowded = Set(segments.filter { $0.lane >= limit }.flatMap(\.columns))
        return segments.filter {
            $0.lane < limit && (!reservingOverflow || $0.lane != limit - 1 || crowded.isDisjoint(with: $0.columns))
        }
    }
}
