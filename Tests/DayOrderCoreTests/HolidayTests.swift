import Foundation
import Testing
@testable import DayOrderCore

@Suite(.serialized) struct HolidayTests {
    private func document(year: Int = 2026, date: String = "2026-10-01", off: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "year": year, "papers": ["https://www.gov.cn/zhengce/test.htm"],
            "days": [["name": "国庆节", "date": date, "isOffDay": off]]
        ])
    }

    @Test func bundledArrangementsAndOrdinaryWeekend() throws {
        let engine = try CalendarEngine()
        let schedule = HolidaySchedule(years: try HolidayYear.bundled())
        for (year, count) in [(2024, 36), (2025, 33), (2026, 39)] {
            #expect(schedule.years[year]?.days.count == count)
        }
        #expect(schedule.day(engine.info(for: engine.date(2026, 10, 1)))?.badge == "休")
        #expect(schedule.day(engine.info(for: engine.date(2026, 10, 10)))?.badge == "班")
        #expect(schedule.day(engine.info(for: engine.date(2026, 10, 11))) == nil)
        #expect(schedule.day(engine.info(for: engine.date(2025, 10, 6)))?.name == "国庆节、中秋节")
        // 上游未列出的连休周末不自行扩充成放假记录。
        #expect(schedule.day(engine.info(for: engine.date(2024, 6, 9))) == nil)
        #expect(schedule.coverageMessage(for: engine.info(for: engine.date(2023, 1, 1))) != nil)
        #expect(schedule.coverageMessage(for: engine.info(for: engine.date(2026, 12, 31))) != nil)
    }

    @Test func nextYearOverridesDecemberAndUnknownIsNotWorkday() throws {
        let engine = try CalendarEngine()
        let current = try HolidayYear.decode(document(date: "2026-12-31"), expectedYear: 2026)
        let next = try HolidayYear.decode(document(year: 2027, date: "2026-12-31", off: false), expectedYear: 2027)
        let schedule = HolidaySchedule(years: [2026: current, 2027: next])
        #expect(schedule.day(engine.info(for: engine.date(2026, 12, 31)))?.isOffDay == false)
        #expect(schedule.coverageMessage(for: engine.info(for: engine.date(2026, 12, 31))) == nil)
        #expect(schedule.day(engine.info(for: engine.date(2028, 1, 1))) == nil)
        #expect(schedule.coverageMessage(for: engine.info(for: engine.date(2028, 1, 1))) != nil)
    }

    @Test func rejectMalformedAndUnpublishedData() throws {
        let valid = try document()
        #expect(throws: HolidayError.invalidData) { try HolidayYear.decode(valid, expectedYear: 2025) }
        for date in ["2026-02-30", "2026-13-01", "2026-1-1", "2025-11-30", "2027-01-01"] {
            #expect(throws: HolidayError.invalidData) { try HolidayYear.decode(document(date: date), expectedYear: 2026) }
        }
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        let day = try #require((object["days"] as? [[String: Any]])?.first)
        object["days"] = [day, day]
        #expect(throws: HolidayError.invalidData) {
            try HolidayYear.decode(JSONSerialization.data(withJSONObject: object), expectedYear: 2026)
        }
        object["days"] = [day]
        object["papers"] = ["https://example.org/fake"]
        #expect(throws: HolidayError.invalidData) {
            try HolidayYear.decode(JSONSerialization.data(withJSONObject: object), expectedYear: 2026)
        }
        #expect(throws: HolidayError.invalidData) { try HolidayYear.decode(Data("<html>error</html>".utf8), expectedYear: 2026) }
        #expect(throws: HolidayError.invalidData) { try HolidayYear.decode(Data(repeating: 0, count: HolidayYear.maximumBytes + 1), expectedYear: 2026) }
        #expect(throws: HolidayError.unavailable) {
            try HolidayYear.decode(Data(#"{"year":2027,"papers":[],"days":[]}"#.utf8), expectedYear: 2027)
        }
    }

    @Test func updateCacheReloadAndFailurePreservesAcceptedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HolidayURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let repository = HolidayRepository(cacheDirectory: directory, session: session)
        HolidayURLProtocol.fixture.set(data: try document())
        let loaded = try await repository.update(year: 2026)
        #expect(loaded.days.first?.isOffDay == true)
        let reloaded = await HolidayRepository(cacheDirectory: directory).cached(year: 2026)
        #expect(reloaded?.days == loaded.days)
        let file = directory.appendingPathComponent("2026.json")
        let accepted = try Data(contentsOf: file)
        for (status, data) in [(404, Data()), (500, Data()), (200, Data("bad json".utf8)),
                               (200, Data(repeating: 32, count: HolidayYear.maximumBytes + 1))] {
            HolidayURLProtocol.fixture.set(data: data, status: status)
            await #expect(throws: (any Error).self) { try await repository.update(year: 2026) }
            #expect(try Data(contentsOf: file) == accepted)
        }
        HolidayURLProtocol.fixture.set(data: Data(), error: URLError(.timedOut))
        await #expect(throws: URLError.self) { try await repository.update(year: 2026) }
        #expect(try Data(contentsOf: file) == accepted)
        HolidayURLProtocol.fixture.set(data: try document())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.update(year: 2026)
        }
        do {
            _ = try await cancelled.value
            Issue.record("已取消的更新不应成功")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        #expect(try Data(contentsOf: file) == accepted)
        try Data("broken cache".utf8).write(to: file)
        #expect(await repository.cached(year: 2026) == nil)
        #expect(try HolidayYear.bundled()[2026] != nil)
    }
}

private final class HolidayURLProtocol: URLProtocol, @unchecked Sendable {
    final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var response: (Data, Int, URLError?) = (Data(), 200, nil)
        func set(data: Data, status: Int = 200, error: URLError? = nil) {
            lock.withLock { response = (data, status, error) }
        }
        func get() -> (Data, Int, URLError?) { lock.withLock { response } }
    }
    static let fixture = Fixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, status, error) = Self.fixture.get()
        if let error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
