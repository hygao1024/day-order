import Foundation

public actor HolidayRepository {
    private let cacheDirectory: URL
    private let session: URLSession

    public init(cacheDirectory: URL, session: URLSession? = nil) {
        self.cacheDirectory = cacheDirectory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func cached(year: Int) -> HolidayYear? {
        guard HolidayYear.supportedYears.contains(year),
              let size = try? cacheURL(year).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= HolidayYear.maximumBytes,
              let data = try? Data(contentsOf: cacheURL(year)) else { return nil }
        return try? HolidayYear.decode(data, expectedYear: year)
    }

    public func update(year: Int) async throws -> HolidayYear {
        guard HolidayYear.supportedYears.contains(year) else { throw HolidayError.unavailable }
        let url = URL(string: "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/\(year).json")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HolidayError.invalidData }
        guard http.statusCode != 404 else { throw HolidayError.unavailable }
        guard http.statusCode == 200 else { throw HolidayError.http(http.statusCode) }
        guard response.expectedContentLength <= HolidayYear.maximumBytes else { throw HolidayError.invalidData }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < HolidayYear.maximumBytes else { throw HolidayError.invalidData }
            data.append(byte)
        }
        let value = try HolidayYear.decode(data, expectedYear: year)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try data.write(to: cacheURL(year), options: .atomic)
        return value
    }

    private func cacheURL(_ year: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(year).json")
    }
}
