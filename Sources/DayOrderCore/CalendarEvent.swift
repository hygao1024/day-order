import Foundation

public enum CalendarEventDisplay: String, CaseIterable, Sendable {
    case detailed, compact, dots, hidden

    public var title: String {
        switch self {
        case .detailed: "详细"
        case .compact: "精简"
        case .dots: "圆点"
        case .hidden: "隐藏"
        }
    }
}

public struct CalendarEvent: Equatable, Sendable {
    public struct Color: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let color: Color

    public init(id: String, title: String, start: Date, end: Date, allDay: Bool, color: Color) {
        self.id = id
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? "无标题日程" : trimmed
        self.start = start
        self.end = end
        self.allDay = allDay
        self.color = color
    }
}

public struct CalendarEventIndex: Sendable {
    public private(set) var days: [Date: [CalendarEvent]] = [:]

    // 事件使用设备时区的民用日期，键转换为现有历法引擎的北京时间中午。
    // 结束时刻不包含在事件区间内，午夜结束不会污染次日。
    public init(events: [CalendarEvent], range: DateInterval, timeZone: TimeZone, engine: CalendarEngine) {
        guard range.duration > 0 else { return }
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        var seen: [String: Set<Date>] = [:]
        let sorted = events.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
        for event in sorted {
            guard event.end >= event.start, event.start < range.end,
                  event.end > range.start || (event.start == event.end && event.start >= range.start),
                  seen[event.id, default: []].insert(event.start).inserted else { continue }
            var day = local.startOfDay(for: max(event.start, range.start))
            let limit = min(event.end, range.end)
            repeat {
                let parts = local.dateComponents([.year, .month, .day], from: day)
                let key = engine.date(parts.year!, parts.month!, parts.day!)
                if engine.isSupported(key) { days[key, default: []].append(event) }
                guard let next = local.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            } while day < limit
        }
    }
}
