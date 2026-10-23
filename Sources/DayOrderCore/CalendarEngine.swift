import Foundation

public enum AnnotationKind: String, Sendable {
    case traditional, civil, western, worldDay, solarTerm
}

public struct Annotation: Equatable, Sendable {
    public let title: String
    public let kind: AnnotationKind
    public let shortTitle: String

    init(title: String, kind: AnnotationKind, shortTitle: String? = nil) {
        self.title = title
        self.kind = kind
        self.shortTitle = shortTitle ?? title
    }
}

public struct DayInfo: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let year: Int
    public let month: Int
    public let day: Int
    public let weekday: Int
    public let lunarLabel: String
    public let lunarFull: String
    public let annotations: [Annotation]
}

/// 日期以北京时间中午表示民用日期；设备所在时区只决定“今天”的公历年月日。
public struct CalendarEngine: Sendable {
    public static let years = 1901...2100
    public let calendar: Calendar
    private let solarTerms: [String: String]
    private let lunarMonths: [(start: Date, month: Int)]

    private struct CalendarData: Decodable {
        let solarTerms: [String: String]
        let lunarMonths: [String: Int]
    }

    public init() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        gregorian.locale = Locale(identifier: "zh_CN")
        calendar = gregorian
        let appBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("DayOrder_DayOrderCore.bundle")) }
        let resources = appBundle ?? Bundle.module
        guard let url = resources.url(forResource: "calendar-data", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try JSONDecoder().decode(CalendarData.self, from: Data(contentsOf: url))
        solarTerms = data.solarTerms
        lunarMonths = try data.lunarMonths.sorted { $0.key < $1.key }.map { key, month in
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, (1...12).contains(abs(month)),
                  let date = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (date, month)
        }
        guard solarTerms.count == Self.years.count * 24, lunarMonths.count > 2400,
              lunarMonths.first?.start == gregorian.date(from: DateComponents(year: 1900, month: 12, day: 22, hour: 12)),
              lunarMonths.last?.start == gregorian.date(from: DateComponents(year: 2100, month: 12, day: 31, hour: 12)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    public func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    public func today(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: now)
        return date(parts.year!, parts.month!, parts.day!)
    }

    public func isSupported(_ date: Date) -> Bool {
        Self.years.contains(calendar.component(.year, from: date))
    }

    public func clamped(_ value: Date) -> Date {
        min(max(value, date(Self.years.lowerBound, 1, 1)), date(Self.years.upperBound, 12, 31))
    }

    public func addingDays(_ amount: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: amount, to: date)!
    }

    public func addingMonths(_ amount: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: amount, to: date)!
    }

    public func monthStart(_ value: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: value)
        return date(parts.year!, parts.month!, 1)
    }

    public func monthDays(containing value: Date, firstWeekday: Int = 2) -> [DayInfo] {
        let start = monthStart(value)
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        let weekday = calendar.component(.weekday, from: start)
        let offset = (weekday - (firstWeekday == 1 ? 1 : 2) + 7) % 7
        let cells = ((offset + count + 6) / 7) * 7
        return (0..<cells).map { info(for: addingDays($0 - offset, to: start)) }
    }

    public func info(for date: Date) -> DayInfo {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard isSupported(date), let chinese = lunarDate(for: date) else {
            return DayInfo(date: date, year: parts.year!, month: parts.month!, day: parts.day!, weekday: parts.weekday!,
                           lunarLabel: "", lunarFull: "超出支持范围", annotations: [])
        }
        let month = abs(chinese.month)
        let day = chinese.day
        let leap = chinese.month < 0
        let monthName = (leap ? "闰" : "") + Self.lunarMonths[month - 1] + "月"
        let dayName = Self.lunarDays[day - 1]
        let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let term = solarTerms[key]
        var annotations: [Annotation] = []
        if !leap, let festival = Self.traditional[month * 100 + day] {
            annotations.append(Annotation(title: festival, kind: .traditional))
        }
        if let tomorrow = lunarDate(for: addingDays(1, to: date)), tomorrow.month == 1 && tomorrow.day == 1 {
            annotations.append(Annotation(title: "除夕", kind: .traditional))
        }
        if term == "清明" {
            annotations.append(Annotation(title: "清明节", kind: .traditional))
        }
        if let festival = Self.civil[parts.month! * 100 + parts.day!] {
            annotations.append(Annotation(title: festival, kind: .civil))
        }
        if let festival = Self.western[parts.month! * 100 + parts.day!] {
            annotations.append(Annotation(title: festival, kind: .western))
        }
        if let worldDay = Self.worldDays[parts.month! * 100 + parts.day!] {
            annotations.append(Annotation(title: worldDay.title, kind: .worldDay, shortTitle: worldDay.shortTitle))
        }
        if let term {
            annotations.append(Annotation(title: term, kind: .solarTerm))
        }
        return DayInfo(date: date, year: parts.year!, month: parts.month!, day: parts.day!,
                       weekday: parts.weekday!, lunarLabel: day == 1 ? monthName : dayName,
                       lunarFull: "农历" + monthName + dayName, annotations: annotations)
    }

    private func lunarDate(for date: Date) -> (month: Int, day: Int)? {
        var lower = 0
        var upper = lunarMonths.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lunarMonths[middle].start <= date { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return nil }
        let start = lunarMonths[lower - 1]
        let day = calendar.dateComponents([.day], from: start.start, to: date).day! + 1
        guard (1...30).contains(day) else { return nil }
        return (start.month, day)
    }

    private static let lunarMonths = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
    private static let lunarDays = ["初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                                    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                                    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
    private static let traditional = [101: "春节", 115: "元宵节", 202: "龙抬头", 505: "端午节",
                                       707: "七夕", 715: "中元节", 815: "中秋节", 909: "重阳节", 1208: "腊八节"]
    private static let civil = [101: "元旦", 308: "妇女节", 501: "劳动节", 504: "青年节",
                               601: "儿童节", 801: "建军节", 910: "教师节", 1001: "国庆节"]
    private static let worldDays: [Int: (title: String, shortTitle: String)] = [
        322: ("世界水日", "世界水日"),
        324: ("世界防治结核病日", "防结核日"),
        407: ("世界卫生日", "卫生日"),
        422: ("国际地球母亲日", "地球日"),
        423: ("世界图书与版权日", "读书日"),
        531: ("世界无烟日", "无烟日"),
        605: ("世界环境日", "环境日"),
        608: ("世界海洋日", "海洋日"),
        921: ("国际和平日", "和平日"),
        1010: ("世界精神卫生日", "精神卫生"),
        1016: ("世界粮食日", "粮食日"),
        1201: ("世界艾滋病日", "艾滋病日"),
        1203: ("国际残疾人日", "残疾人日")
    ]
    private static let western = [214: "情人节", 1031: "万圣夜", 1224: "平安夜", 1225: "圣诞节"]
}
