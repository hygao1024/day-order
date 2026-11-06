import AppKit
import DayOrderCore
import EventKit
import SwiftUI

enum CalendarAuthorization: Sendable {
    case notDetermined, fullAccess, denied, restricted, writeOnly
}

protocol SystemCalendarSource: Sendable {
    func authorization() async -> CalendarAuthorization
    func requestAccess() async throws -> CalendarAuthorization
    func events(in range: DateInterval) async throws -> [CalendarEvent]
}

actor EventKitCalendarSource: SystemCalendarSource {
    private let store = EKEventStore()

    func authorization() -> CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        @unknown default: .denied
        }
    }

    func requestAccess() async throws -> CalendarAuthorization {
        guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") is String else {
            throw NSError(domain: "DayOrder.SystemCalendar", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请打开构建后的 DayOrder.app，再授权日历访问。"])
        }
        // 读取需要 full access；系统没有只读授权档位，应用不调用任何写入 API。
        let _: Bool = try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
        return authorization()
    }

    func events(in range: DateInterval) throws -> [CalendarEvent] {
        guard authorization() == .fullAccess else { throw CocoaError(.fileReadNoPermission) }
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled, let calendar = event.calendar,
                  let start = event.startDate, let end = event.endDate else { return nil }
            let color = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB) ?? .systemBlue
            return CalendarEvent(id: event.eventIdentifier ?? event.calendarItemIdentifier,
                                 title: event.title ?? "", start: start, end: end,
                                 allDay: event.isAllDay,
                                 color: .init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent))
        }
    }
}

@MainActor
final class SystemCalendarEvents: NSObject, ObservableObject {
    @Published private(set) var mode: CalendarEventDisplay
    @Published private(set) var authorization = CalendarAuthorization.notDetermined
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0
    @Published var permissionSettingsPresented = false
    private(set) var days: [Date: [CalendarEvent]] = [:]
    private let source: any SystemCalendarSource
    private let defaults: UserDefaults
    private var context: (month: Date, engine: CalendarEngine)?
    private var loadTask: Task<Void, Never>?
    private var permissionTask: Task<CalendarAuthorization, Error>?
    private var generation = 0
    private var stopped = false

    init(defaults: UserDefaults = .standard, source: any SystemCalendarSource = EventKitCalendarSource()) {
        self.defaults = defaults
        self.source = source
        mode = CalendarEventDisplay(rawValue: defaults.string(forKey: "calendarEventDisplay") ?? "") ?? .hidden
        super.init()
        for name in [NSNotification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification,
                     .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(sourceChanged), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var statusText: String {
        if mode == .hidden { return "日程已隐藏" }
        if let errorMessage { return errorMessage }
        if loading { return "正在读取系统日历…" }
        switch authorization {
        case .notDetermined: return "选择显示模式以连接系统日历"
        case .denied: return "日历访问被拒绝，请在系统设置中允许访问"
        case .restricted: return "系统限制了日历访问"
        case .writeOnly: return "读取日程需要完整日历访问权限"
        case .fullAccess:
            return days.isEmpty ? "当前浏览范围没有日程" : "系统日历已连接"
        }
    }

    func update(month: Date, engine: CalendarEngine) {
        let restoring = context == nil
        context = (month, engine)
        reload(offerSettings: restoring && mode != .hidden)
    }

    func choose(_ mode: CalendarEventDisplay) {
        permissionSettingsPresented = false
        self.mode = mode
        defaults.set(mode.rawValue, forKey: "calendarEventDisplay")
        reload(offerSettings: mode != .hidden)
    }

    @objc func advance() { choose(mode.next) }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    @objc nonisolated private func sourceChanged() {
        Task { @MainActor [weak self] in self?.reload(debounce: true) }
    }

    func stop() {
        stopped = true
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        NotificationCenter.default.removeObserver(self)
        permissionSettingsPresented = false
        clear()
        loading = false
    }

    private func clear() {
        guard !days.isEmpty else { return }
        days.removeAll()
        revision += 1
    }

    private func reload(offerSettings: Bool = false, debounce: Bool = false) {
        guard !stopped else { return }
        generation += 1
        let serial = generation
        loadTask?.cancel()
        loadTask = nil
        guard mode != .hidden, let context else {
            clear()
            if loading { loading = false }
            if errorMessage != nil { errorMessage = nil }
            return
        }
        errorMessage = nil
        loading = true
        let source = source
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == serial { loading = false; loadTask = nil } }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled, generation == serial else { return }
                var access = await source.authorization()
                try Task.checkCancellation()
                let requestedPermission = access == .notDetermined || access == .writeOnly
                if requestedPermission {
                    if permissionTask == nil {
                        permissionTask = Task { try await source.requestAccess() }
                    }
                    // 隐藏或切月不重复触发系统授权；迟到授权结果仍须通过代际检查。
                    access = try await permissionTask!.value
                    permissionTask = nil
                }
                guard !Task.isCancelled, generation == serial else { return }
                authorization = access
                guard access == .fullAccess else {
                    clear()
                    // 拒绝或受限后只能引导设置；切月和后台通知不重复弹出恢复提示。
                    if offerSettings && !requestedPermission {
                        permissionSettingsPresented = true
                    }
                    return
                }
                var local = Calendar(identifier: .gregorian)
                local.timeZone = .current
                let parts = context.engine.calendar.dateComponents([.year, .month], from: context.month)
                let month = local.date(from: parts)!
                let start = local.date(byAdding: .day, value: -7,
                                       to: local.date(byAdding: .month, value: -1, to: month)!)!
                let end = local.date(byAdding: .day, value: 7,
                                     to: local.date(byAdding: .month, value: 2, to: month)!)!
                let range = DateInterval(start: start, end: end)
                let values = try await source.events(in: range)
                guard !Task.isCancelled, generation == serial else { return }
                let currentAccess = await source.authorization()
                guard !Task.isCancelled, generation == serial else { return }
                authorization = currentAccess
                guard currentAccess == .fullAccess else { clear(); return }
                let next = CalendarEventIndex(events: values, range: range, timeZone: local.timeZone, engine: context.engine).days
                if next != days {
                    days = next
                    revision += 1
                }
            } catch {
                guard !Task.isCancelled, generation == serial else { return }
                permissionTask = nil
                clear()
                errorMessage = "系统日历读取失败：\(error.localizedDescription)"
            }
        }
    }
}

@MainActor extension CalendarEventDisplay {
    var extraRowHeight: CGFloat {
        switch self {
        case .detailed: 26
        case .compact: 10
        case .dots: 6
        case .hidden: 0
        }
    }

    var viewportHeight: CGFloat { CalendarTimelineView.viewportHeight + 6 * extraRowHeight }
}
