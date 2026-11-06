#if DEBUG
import DayOrderCore
import Foundation

// 仅替换操作系统边界，快照仍经过生产控制器、索引、菜单和日期按钮。
actor SmokeCalendarSource: SystemCalendarSource {
    private var access = CalendarAuthorization.notDetermined
    private var grant = CalendarAuthorization.fullAccess
    private var values: [CalendarEvent] = []
    private var failing = false
    private var delay: Duration = .zero
    private(set) var reads = 0
    private(set) var requests = 0
    private var held: CheckedContinuation<[CalendarEvent], Error>?
    private var holdNext = false

    func authorization() -> CalendarAuthorization { access }
    func requestAccess() async throws -> CalendarAuthorization {
        requests += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        access = grant
        return access
    }
    func events(in range: DateInterval) async throws -> [CalendarEvent] {
        reads += 1
        if holdNext {
            holdNext = false
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        if failing { throw CocoaError(.fileReadUnknown) }
        return values
    }
    func configure(access: CalendarAuthorization, grant: CalendarAuthorization = .fullAccess,
                   values: [CalendarEvent] = [], failing: Bool = false, delay: Duration = .zero) {
        self.access = access
        self.grant = grant
        self.values = values
        self.failing = failing
        self.delay = delay
    }
    func holdRead() { holdNext = true }
    var hasHeldRead: Bool { held != nil }
    func finishRead(_ values: [CalendarEvent]) { held?.resume(returning: values); held = nil }
}
#endif
