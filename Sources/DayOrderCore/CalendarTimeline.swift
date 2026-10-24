import Foundation

/// 月份区块拥有周行归属；农历和节日按可见日期获取。
public struct CalendarTimeline {
    public enum Row {
        case month(Date)
        case week(Date, month: Date)

        public var date: Date {
            switch self {
            case .month(let date), .week(let date, _): date
            }
        }

        public var sectionMonth: Date {
            switch self {
            case .month(let month), .week(_, let month): month
            }
        }
    }

    public let rows: [Row]
    public let firstWeekday: Int
    private let monthRows: [Date: Range<Int>]
    private let engine: CalendarEngine

    public init(engine: CalendarEngine, firstWeekday: Int) {
        let weekday = firstWeekday == 1 ? 1 : 2
        self.firstWeekday = weekday
        self.engine = engine
        var rows: [Row] = []
        var monthRows: [Date: Range<Int>] = [:]
        for year in CalendarEngine.years {
            for month in 1...12 {
                let start = engine.date(year, month, 1)
                let count = engine.calendar.range(of: .day, in: .month, for: start)!.count
                let offset = (engine.calendar.component(.weekday, from: start) - weekday + 7) % 7
                let firstWeek = engine.addingDays(-offset, to: start)
                rows.append(.month(start))
                let firstRow = rows.count
                for week in 0..<((offset + count + 6) / 7) {
                    rows.append(.week(engine.addingDays(week * 7, to: firstWeek), month: start))
                }
                monthRows[start] = firstRow..<rows.count
            }
        }
        self.rows = rows
        self.monthRows = monthRows
    }

    /// 使用行的 sectionMonth 查询完整周区间；非区块月初返回 nil。
    public func weekRows(inMonth month: Date) -> Range<Int>? { monthRows[month] }

    /// 默认定位日期自身的月份区块；恢复位置时显式指定区块以区分重复的补位周。
    public func weekRow(containing date: Date, inMonth month: Date? = nil) -> Int {
        let section = engine.monthStart(engine.clamped(month ?? date))
        let range = monthRows[section]!
        let firstWeek = rows[range.lowerBound].date
        let days = engine.calendar.dateComponents([.day], from: firstWeek, to: date).day!
        return range.lowerBound + min(max(0, days / 7), range.count - 1)
    }
}
