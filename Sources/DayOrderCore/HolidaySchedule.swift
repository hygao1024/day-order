import Foundation

public struct HolidayDay: Codable, Equatable, Sendable {
    public let name: String
    public let date: String
    public let isOffDay: Bool

    public var badge: String { isOffDay ? "休" : "班" }
    public var detail: String { name + (isOffDay ? "假期 · 休息" : "调休 · 上班") }
}

public struct HolidayYear: Decodable, Sendable {
    public let year: Int
    public let papers: [URL]
    public let days: [HolidayDay]
    public static let supportedYears = 2007...2101
    public static let maximumBytes = 128 * 1024

    public static func decode(_ data: Data, expectedYear: Int) throws -> HolidayYear {
        guard supportedYears.contains(expectedYear), data.count <= maximumBytes else {
            throw HolidayError.invalidData
        }
        guard let value = try? JSONDecoder().decode(Self.self, from: data) else { throw HolidayError.invalidData }
        if value.year == expectedYear && value.papers.isEmpty && value.days.isEmpty { throw HolidayError.unavailable }
        guard value.year == expectedYear, !value.papers.isEmpty, value.papers.count <= 20,
              value.papers.allSatisfy({ $0.scheme == "https" && $0.host == "www.gov.cn" }),
              !value.days.isEmpty, value.days.count <= 100 else { throw HolidayError.invalidData }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var seen = Set<String>()
        for day in value.days {
            let parts = day.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, day.date == String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2]),
                  parts[0] == expectedYear || (parts[0] == expectedYear - 1 && parts[1] == 12),
                  (1...12).contains(parts[1]), (1...31).contains(parts[2]),
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  calendar.component(.month, from: date) == parts[1],
                  calendar.component(.day, from: date) == parts[2],
                  !day.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, day.name.count <= 30,
                  !day.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(day.date).inserted else { throw HolidayError.invalidData }
        }
        return value
    }

    public static func bundled() throws -> [Int: HolidayYear] {
        let appBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("DayOrder_DayOrderCore.bundle")) }
        let resources = appBundle ?? Bundle.module
        var result: [Int: HolidayYear] = [:]
        for year in 2024...2026 {
            guard let url = resources.url(forResource: "holidays-\(year)", withExtension: "json") else {
                throw HolidayError.invalidData
            }
            result[year] = try decode(Data(contentsOf: url), expectedYear: year)
        }
        return result
    }
}

public struct HolidaySchedule: Sendable {
    public var years: [Int: HolidayYear]

    public init(years: [Int: HolidayYear] = [:]) { self.years = years }

    public func day(_ day: DayInfo) -> HolidayDay? {
        let key = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
        // 翌年通知可能调整本年十二月；更晚年度的明确记录优先。
        return years[day.year + 1]?.days.first { $0.date == key }
            ?? years[day.year]?.days.first { $0.date == key }
    }

    public func coverageMessage(for day: DayInfo) -> String? {
        if years[day.year] == nil { return "\(day.year)年放假安排未收录" }
        if day.month == 12 && years[day.year + 1] == nil { return "翌年跨年安排未收录" }
        return nil
    }
}

public enum HolidayError: Error, LocalizedError, Equatable {
    case invalidData, unavailable, http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidData: "数据校验未通过"
        case .unavailable: "数据源尚未提供该年安排"
        case .http(let code): "数据源请求失败（\(code)）"
        }
    }
}
