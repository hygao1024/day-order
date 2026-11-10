import AppKit
import DayOrderCore
import SwiftUI

struct CalendarView: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var events: SystemCalendarEvents
    let launchAtLogin: LaunchAtLogin
    let appUpdater: AppUpdater
    @AppStorage("showTraditional") private var showTraditional = true
    @AppStorage("showCivil") private var showCivil = true
    @AppStorage("showWestern") private var showWestern = true
    @AppStorage("showWorldDays") private var showWorldDays = true
    @AppStorage("showHolidaySchedule") private var showHolidaySchedule = true
    @AppStorage("showSolarTerms") private var showSolarTerms = true
    @AppStorage("firstWeekday") private var firstWeekday = 2
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("blurEnabled") private var blurEnabled = true
    @AppStorage(CalendarRefreshPolicy.preferenceKey) private var preferHighRefreshRate = false
    @AppStorage("menuBarDisplay") private var menuBarDisplay = MenuBarDisplay.iconAndDate.rawValue
    @AppStorage("menuBarDateFormat") private var menuBarDateFormat = MenuBarDateFormat.monthDayWeekday.rawValue
    let updateMenuBar: () -> Void
    let updatePanelAppearance: (NSAppearance?) -> Void
    let dismiss: () -> Void

    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    private var effectiveWeekday: Int { firstWeekday == 1 ? 1 : 2 }

    var body: some View {
        calendar
        .frame(width: 320)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        // 原生窗口外观会回传到嵌套托管视图，避开 SwiftUI 正在执行的更新轮次。
        .task(id: appearance) { applyAppearance() }
        .task(id: model.displayedYear) { await model.loadHolidayCache(year: model.displayedYear) }
        .task(id: model.month) { events.update(month: model.month, engine: model.engine) }
        .onChange(of: events.mode) { if events.mode == .hidden { model.closeAgenda() } }
        .onChange(of: menuBarDisplay) { updateMenuBar() }
        .onChange(of: menuBarDateFormat) { updateMenuBar() }
        .alert("需要日历访问权限", isPresented: $events.permissionSettingsPresented) {
            Button("打开系统设置") { events.openPrivacySettings() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(events.authorization == .restricted
                 ? "日历访问受系统限制，请检查系统设置或管理策略。"
                 : "请在系统设置的隐私与安全性中，允许日序访问日历。")
        }
        .onExitCommand {
            if model.showingSettings { model.showingSettings = false }
            else if model.showingYearOverview { model.dismissYearLevel() }
            else if model.agenda != nil { model.closeAgenda() }
            else { dismiss() }
        }
    }

    private var calendar: some View {
        CalendarShell(
            header: AnyView(Group {
                if model.showingSettings { settings.header }
                else if model.showingYearOverview { YearOverviewHeader(model: model) }
                else { monthHeader }
            }),
            content: AnyView(Group {
                if model.showingSettings { settings }
                else if model.showingYearOverview {
                    YearCalendarScrollView(model: model, firstWeekday: effectiveWeekday)
                } else {
                    CalendarTimelineView(model: model, events: events, firstWeekday: effectiveWeekday,
                                         options: contentOptions, preferHighRefreshRate: preferHighRefreshRate)
                }
            }),
            footer: AnyView(Group {
                if model.showingSettings { settings.footer }
                else if model.showingYearOverview {
                    Text("点击月份查看 · 滚动浏览年份")
                        .font(.system(size: 10)).foregroundStyle(CalendarSurface.secondaryText)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                } else { detail.padding(12) }
            }),
            yearOverview: model.showingYearOverview, showingSettings: model.showingSettings,
            blurEnabled: blurEnabled,
            calendarHeight: events.mode.viewportHeight)
    }

    private var monthHeader: some View {
        let month = model.engine.info(for: model.month)
        return VStack(spacing: 12) {
            HStack(spacing: 6) {
                Button { model.openYearOverview() } label: {
                    Text("\(String(month.year))年\(month.month)月")
                        .font(.system(size: 16, weight: .semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("浏览年份和月份")
                .accessibilityLabel("年概览，当前\(String(month.year))年\(month.month)月")
                Spacer(minLength: 0)
                CalendarEventToggle(events: events).frame(width: 24, height: 24)
                monthNavigation
            }
            HStack(spacing: 0) {
                ForEach(0..<7) { index in
                    Text(weekdays[(effectiveWeekday - 1 + index) % 7])
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CalendarSurface.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
        .padding(12)
    }

    private var monthNavigation: some View {
        HStack(spacing: 0) {
            Button { model.moveMonth(-1, animated: true) } label: {
                Image(systemName: "chevron.left").frame(width: 28, height: 24)
            }
            .disabled(!model.canMoveMonth(-1))
            .help("上个月（Page Up）")
            .accessibilityLabel("上个月")
            navigationDivider
            Button { model.goToToday(animated: true) } label: {
                Text("今天").frame(width: 44, height: 24)
            }
            .help("回到今天（Home）")
            navigationDivider
            Button { model.moveMonth(1, animated: true) } label: {
                Image(systemName: "chevron.right").frame(width: 28, height: 24)
            }
            .disabled(!model.canMoveMonth(1))
            .help("下个月（Page Down）")
            .accessibilityLabel("下个月")
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(CalendarNavigationButtonStyle())
        .background(.primary.opacity(0.045), in: Capsule())
        .clipShape(Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5).allowsHitTesting(false) }
    }

    private var navigationDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.14))
            .frame(width: 0.5, height: 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var detail: some View {
        let day = model.engine.info(for: model.selection)
        let prefix = model.selection == model.today ? "今天 · " : ""
        let annotations = visibleAnnotations(day)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(prefix)\(day.month)月\(day.day)日")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("周" + weekdays[day.weekday - 1])
                    .font(.system(size: 11)).foregroundStyle(CalendarSurface.secondaryText)
                Button { model.showingSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 14)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("设置")
                .accessibilityLabel("设置")
            }
            Text(([day.lunarFull] + annotations.map(\.title)).joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(CalendarSurface.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if showHolidaySchedule {
                if let holiday = model.holidays.day(day) {
                    Text(holiday.detail)
                        .font(.system(size: 11)).foregroundStyle(CalendarSurface.secondaryText)
                }
                if let message = model.holidays.coverageMessage(for: day) {
                    Text(message).font(.system(size: 10)).foregroundStyle(CalendarSurface.secondaryText)
                }
            }
            if !annotations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(annotations, id: \.title) { annotation in
                        if let summary = annotation.summary {
                            (Text(annotation.title + " · ").fontWeight(.medium) + Text(summary))
                                .font(.system(size: 11))
                                .foregroundStyle(CalendarSurface.secondaryText)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var settings: CalendarSettingsView {
        CalendarSettingsView(model: model, launchAtLogin: launchAtLogin, appUpdater: appUpdater,
                             menuBarDisplay: $menuBarDisplay, menuBarDateFormat: $menuBarDateFormat,
                             appearance: $appearance, blurEnabled: $blurEnabled, firstWeekday: $firstWeekday,
                             preferHighRefreshRate: $preferHighRefreshRate,
                             showTraditional: $showTraditional, showCivil: $showCivil,
                             showWestern: $showWestern, showWorldDays: $showWorldDays,
                             showSolarTerms: $showSolarTerms, showHolidaySchedule: $showHolidaySchedule)
    }

    private var contentOptions: CalendarContentOptions {
        CalendarContentOptions(traditional: showTraditional, civil: showCivil, western: showWestern,
                               worldDays: showWorldDays, solarTerms: showSolarTerms, holidaySchedule: showHolidaySchedule)
    }

    private func visibleAnnotations(_ day: DayInfo) -> [Annotation] {
        contentOptions.annotations(for: day)
    }

    private func applyAppearance() {
        NSApp.appearance = appearance == "light" ? NSAppearance(named: .aqua)
            : appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
        updatePanelAppearance(NSApp.appearance)
    }
}

private struct CalendarNavigationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.45))
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.12 : isHovered ? 0.06 : 0) : 0))
            .onHover { isHovered = $0 }
    }
}
