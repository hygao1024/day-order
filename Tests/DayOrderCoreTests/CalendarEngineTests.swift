import Foundation
import Testing
@testable import DayOrderCore

@Suite struct CalendarEngineTests {
    let engine = try! CalendarEngine()

    @Test func menuBarDateFormats() {
        let day = engine.info(for: engine.date(2026, 10, 23))
        #expect(MenuBarDateFormat.monthDayWeekday.title(for: day) == "10月23日 周五")
        #expect(MenuBarDateFormat.yearMonthDay.title(for: day) == "2026年10月23日")
        #expect(MenuBarDateFormat.yearMonthDayWeekday.title(for: day) == "2026年10月23日 周五")
        #expect(MenuBarDateFormat.numericDate.title(for: day) == "2026-10-23")
        let newYear = engine.info(for: engine.date(2027, 1, 1))
        #expect(MenuBarDateFormat.numericDate.title(for: newYear) == "2027-01-01")
        #expect(MenuBarDateFormat.yearMonthDayWeekday.title(for: newYear) == "2027年1月1日 周五")
        #expect(MenuBarDateFormat(rawValue: "unknown") == nil)
        #expect(MenuBarDisplay(rawValue: "unknown") == nil)
    }

    @Test func correctedDesignDates() {
        let day = engine.info(for: engine.date(2026, 10, 23))
        #expect(day.lunarFull == "农历九月十四")
        #expect(day.annotations.map(\.title) == ["霜降"])
        #expect(engine.info(for: engine.date(2026, 10, 18)).annotations.map(\.title) == ["重阳节"])
        #expect(engine.info(for: engine.date(2026, 10, 19)).annotations.isEmpty)
        #expect(engine.info(for: engine.date(2026, 10, 31)).lunarFull == "农历九月廿二")
    }

    @Test func lunarFestivalsAndNewYearsEve() {
        let fixtures: [(Int, Int, Int, String)] = [
            (2024, 2, 9, "除夕"), (2025, 1, 28, "除夕"), (2026, 2, 16, "除夕"),
            (2026, 2, 17, "春节"), (2026, 3, 3, "元宵节"), (2026, 6, 19, "端午节"),
            (2026, 9, 25, "中秋节")
        ]
        for (year, month, day, festival) in fixtures {
            #expect(engine.info(for: engine.date(year, month, day)).annotations.contains { $0.title == festival })
        }
    }

    @Test func leapLunarMonthDoesNotDuplicateFestival() {
        // 2023 年闰二月初二，不重复普通二月初二的龙抬头。
        let leapDay = engine.info(for: engine.date(2023, 3, 23))
        #expect(leapDay.lunarFull == "农历闰二月初二")
        #expect(!leapDay.annotations.contains { $0.title == "龙抬头" })
        #expect(engine.info(for: engine.date(2023, 2, 21)).annotations.contains { $0.title == "龙抬头" })
        #expect(engine.info(for: engine.date(2025, 7, 25)).lunarLabel == "闰六月")
    }

    @Test func officialDatesWhereSystemCalendarReturnedDayZero() {
        #expect(engine.info(for: engine.date(2057, 9, 28)).lunarFull == "农历九月初一")
        #expect(engine.info(for: engine.date(2057, 9, 27)).lunarFull == "农历八月廿九")
        #expect(engine.info(for: engine.date(2097, 8, 7)).lunarFull == "农历七月初一")
        #expect(engine.info(for: engine.date(2097, 8, 6)).lunarFull == "农历六月廿九")
    }

    @Test func westernFestivals() {
        for (month, day, title) in [(2, 14, "情人节"), (10, 31, "万圣夜"), (12, 24, "平安夜"), (12, 25, "圣诞节")] {
            let info = engine.info(for: engine.date(2026, month, day))
            #expect(info.annotations.contains { $0.title == title && $0.kind == .western })
        }
        #expect(!engine.info(for: engine.date(2026, 12, 26)).annotations.contains { $0.title == "圣诞节" })
    }

    @Test func chineseCivilFestivals() {
        let fixtures = [(1, 1, "元旦"), (3, 8, "妇女节"), (5, 1, "劳动节"), (5, 4, "青年节"),
                        (6, 1, "儿童节"), (8, 1, "建军节"), (9, 10, "教师节"), (10, 1, "国庆节")]
        for (month, day, title) in fixtures {
            let date = engine.date(2026, month, day)
            let festival = engine.info(for: date).annotations.first { $0.title == title }
            #expect(festival?.kind.rawValue == "civil", "\(month)月\(day)日应显示\(title)")
            #expect(!engine.info(for: engine.addingDays(1, to: date)).annotations.contains { $0.title == title })
        }
    }

    @Test func worldDays() {
        let fixtures = [(3, 22, "世界水日"), (3, 24, "世界防治结核病日"), (4, 7, "世界卫生日"),
                        (4, 22, "国际地球母亲日"), (4, 23, "世界图书与版权日"), (5, 31, "世界无烟日"),
                        (6, 5, "世界环境日"), (6, 8, "世界海洋日"), (9, 21, "国际和平日"),
                        (10, 10, "世界精神卫生日"), (10, 16, "世界粮食日"),
                        (12, 1, "世界艾滋病日"), (12, 3, "国际残疾人日")]
        for year in [1901, 2026, 2027, 2100] {
            for (month, day, title) in fixtures {
                let date = engine.date(year, month, day)
                let matches = engine.info(for: date).annotations.filter { $0.title == title }
                #expect(matches.count == 1)
                #expect(matches.first?.kind == .worldDay)
                #expect((1...4).contains(matches.first?.shortTitle.count ?? 0))
                #expect(!engine.info(for: engine.addingDays(1, to: date)).annotations.contains { $0.title == title })
            }
        }
    }

    @Test func worldDayAndSolarTermCollision() {
        let annotations = engine.info(for: engine.date(2026, 6, 5)).annotations
        #expect(annotations.map(\.title) == ["世界环境日", "芒种"])
        #expect(engine.info(for: engine.date(2026, 3, 8)).annotations.filter { $0.title.contains("妇女") }.count == 1)
    }

    @Test func traditionalAndCivilFestivalCollision() {
        let day = engine.info(for: engine.date(2020, 10, 1))
        #expect(day.annotations.map(\.title) == ["中秋节", "国庆节"])
        #expect(day.lunarFull == "农历八月十五")
    }

    @Test func solarTermsReferenceAndCollision() {
        let fixtures = [(1, 5, "小寒"), (2, 4, "立春"), (3, 20, "春分"), (4, 5, "清明"),
                        (6, 21, "夏至"), (9, 23, "秋分"), (10, 8, "寒露"), (10, 23, "霜降"), (12, 22, "冬至")]
        for (month, day, title) in fixtures {
            #expect(engine.info(for: engine.date(2026, month, day)).annotations.contains { $0.title == title })
        }
        let qingming = engine.info(for: engine.date(2026, 4, 5)).annotations
        #expect(qingming.map(\.title) == ["清明节", "清明"])
    }

    @Test func fullSolarTermCoverage() {
        for year in CalendarEngine.years {
            var total = 0
            for month in 1...12 {
                var count = 0
                for day in 1...31 {
                    let date = engine.date(year, month, day)
                    guard engine.calendar.component(.month, from: date) == month else { continue }
                    let info = engine.info(for: date)
                    #expect(info.lunarFull.hasPrefix("农历"), "\(year)-\(month)-\(day) 必须有有效农历")
                    count += info.annotations.filter { $0.kind == .solarTerm }.count
                }
                #expect(count == 2, "\(year)年\(month)月应有两个节气")
                total += count
            }
            #expect(total == 24)
        }
    }

    @Test func monthLayoutAndLeapYear() {
        let october = engine.monthDays(containing: engine.date(2026, 10, 1))
        #expect(october.count == 35)
        #expect(october.first?.date == engine.date(2026, 9, 28))
        #expect(october.last?.date == engine.date(2026, 11, 1))
        #expect(october[25].day == 23)
        #expect(engine.monthDays(containing: engine.date(2026, 3, 1)).count == 42)
        #expect(engine.monthDays(containing: engine.date(2021, 2, 1)).count == 28)
        #expect(engine.monthDays(containing: engine.date(2024, 2, 1)).contains { $0.month == 2 && $0.day == 29 })
        let sunday = engine.monthDays(containing: engine.date(2026, 10, 1), firstWeekday: 1)
        #expect(sunday.first?.weekday == 1)
        #expect(sunday.first?.date == engine.date(2026, 9, 27))
        #expect(engine.monthDays(containing: engine.date(2026, 10, 1), firstWeekday: 999).first?.weekday == 2)
    }

    @Test func calendarArithmeticAndBounds() {
        #expect(engine.addingMonths(1, to: engine.date(2026, 1, 31)) == engine.date(2026, 2, 28))
        #expect(engine.addingDays(1, to: engine.date(2026, 12, 31)) == engine.date(2027, 1, 1))
        #expect(!engine.isSupported(engine.date(1900, 12, 31)))
        #expect(!engine.isSupported(engine.date(2101, 1, 1)))
        #expect(engine.isSupported(engine.date(1901, 1, 1)))
        #expect(engine.isSupported(engine.date(2100, 12, 31)))
        #expect(engine.clamped(engine.date(1800, 1, 1)) == engine.date(1901, 1, 1))
        #expect(engine.clamped(engine.date(2200, 1, 1)) == engine.date(2100, 12, 31))
    }

    @Test func localTodayAcrossTimeZonesAndDST() {
        let instant = ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z")!
        #expect(engine.today(now: instant, timeZone: TimeZone(identifier: "Asia/Shanghai")!) == engine.date(2026, 10, 23))
        #expect(engine.today(now: instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == engine.date(2026, 10, 22))
        let dst = ISO8601DateFormatter().date(from: "2026-03-08T10:30:00Z")!
        #expect(engine.today(now: dst, timeZone: TimeZone(identifier: "America/Los_Angeles")!) == engine.date(2026, 3, 8))
    }
}
