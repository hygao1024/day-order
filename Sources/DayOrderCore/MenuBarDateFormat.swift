import Foundation

public enum MenuBarDateFormat: String, CaseIterable, Sendable {
    case monthDayWeekday, yearMonthDay, yearMonthDayWeekday, numericDate

    public func title(for day: DayInfo) -> String {
        let weekday = ["日", "一", "二", "三", "四", "五", "六"][day.weekday - 1]
        switch self {
        case .monthDayWeekday: return "\(day.month)月\(day.day)日 周\(weekday)"
        case .yearMonthDay: return "\(day.year)年\(day.month)月\(day.day)日"
        case .yearMonthDayWeekday: return "\(day.year)年\(day.month)月\(day.day)日 周\(weekday)"
        case .numericDate: return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        }
    }
}

public enum MenuBarDisplay: String, CaseIterable, Sendable {
    case iconAndDate, dateOnly, iconOnly
}
