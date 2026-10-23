import AppKit
import DayOrderCore
import SwiftUI

struct CalendarView: View {
    @ObservedObject var model: CalendarModel
    @AppStorage("showTraditional") private var showTraditional = true
    @AppStorage("showCivil") private var showCivil = true
    @AppStorage("showWestern") private var showWestern = true
    @AppStorage("showWorldDays") private var showWorldDays = true
    @AppStorage("showHolidaySchedule") private var showHolidaySchedule = true
    @AppStorage("showSolarTerms") private var showSolarTerms = true
    @AppStorage("firstWeekday") private var firstWeekday = 2
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("menuBarDisplay") private var menuBarDisplay = MenuBarDisplay.iconAndDate.rawValue
    @AppStorage("menuBarDateFormat") private var menuBarDateFormat = MenuBarDateFormat.monthDayWeekday.rawValue
    let updateMenuBar: () -> Void
    let dismiss: () -> Void

    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    private let accent = Color(red: 0.89, green: 0.20, blue: 0.15)
    private var effectiveWeekday: Int { firstWeekday == 1 ? 1 : 2 }

    var body: some View {
        VStack(spacing: 0) {
            if model.showingSettings {
                settings.padding(12).background(CalendarSurface.settings)
            } else if model.showingYearOverview {
                YearOverviewView(model: model, firstWeekday: effectiveWeekday)
            } else {
                calendar
            }
        }
        .frame(width: 320)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .onAppear(perform: applyAppearance)
        .task(id: model.displayedYear) { await model.loadHolidayCache(year: model.displayedYear) }
        .onChange(of: appearance) { applyAppearance() }
        .onChange(of: menuBarDisplay) { updateMenuBar() }
        .onChange(of: menuBarDateFormat) { updateMenuBar() }
        .onExitCommand {
            if model.showingYearOverview { model.dismissYearLevel() }
            else if model.showingSettings { model.showingSettings = false }
            else { dismiss() }
        }
    }

    private var calendar: some View {
        let month = model.engine.info(for: model.month)
        let days = model.engine.monthDays(containing: model.month, firstWeekday: effectiveWeekday)
        return VStack(spacing: 0) {
            VStack(spacing: 12) {
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
                    Button { model.moveMonth(-1) } label: {
                        Image(systemName: "chevron.left").frame(width: 12, height: 18)
                    }
                    .disabled(!model.canMoveMonth(-1))
                    .help("上个月（Page Up）")
                    .accessibilityLabel("上个月")
                    Button { model.goToToday() } label: { Text("今天").frame(height: 18) }
                        .help("回到今天（Home）")
                    Button { model.moveMonth(1) } label: {
                        Image(systemName: "chevron.right").frame(width: 12, height: 18)
                    }
                    .disabled(!model.canMoveMonth(1))
                    .help("下个月（Page Down）")
                    .accessibilityLabel("下个月")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                HStack(spacing: 2) {
                    ForEach(0..<7) { index in
                        Text(weekdays[(effectiveWeekday - 1 + index) % 7])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
            }
            .padding(12)
            .background(CalendarSurface.chrome)
            Divider().opacity(0.3)
            VStack(spacing: 0) {
                ForEach(0..<(days.count / 7), id: \.self) { week in
                    if week > 0 { Divider().opacity(0.55) }
                    HStack(spacing: 2) {
                        ForEach(Array(days[(week * 7)..<(week * 7 + 7)])) { day in
                            DayCell(day: day, annotation: visibleAnnotations(day).first,
                                    holiday: showHolidaySchedule ? model.holidays.day(day) : nil,
                                    isToday: day.date == model.today, isSelected: day.date == model.selection,
                                    isInMonth: day.month == month.month, accent: accent) {
                                model.select(day.date)
                            }
                            .disabled(!model.engine.isSupported(day.date))
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 12)
            .background(CalendarSurface.content)
            Divider().opacity(0.3)
            detail.padding(12).background(CalendarSurface.chrome)
        }
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
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if showHolidaySchedule {
                if let holiday = model.holidays.day(day) {
                    Text(holiday.detail)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let message = model.holidays.coverageMessage(for: day) {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !annotations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(annotations, id: \.title) { annotation in
                        if let summary = annotation.summary {
                            (Text(annotation.title + " · ").fontWeight(.medium) + Text(summary))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
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

    private var settings: some View {
        CalendarSettingsView(model: model,
                             menuBarDisplay: $menuBarDisplay, menuBarDateFormat: $menuBarDateFormat,
                             appearance: $appearance, firstWeekday: $firstWeekday,
                             showTraditional: $showTraditional, showCivil: $showCivil,
                             showWestern: $showWestern, showWorldDays: $showWorldDays,
                             showSolarTerms: $showSolarTerms, showHolidaySchedule: $showHolidaySchedule)
    }

    private func visibleAnnotations(_ day: DayInfo) -> [Annotation] {
        day.annotations.filter {
            switch $0.kind {
            case .traditional: showTraditional
            case .civil: showCivil
            case .western: showWestern
            case .worldDay: showWorldDays
            case .solarTerm: showSolarTerms
            }
        }
    }

    private func applyAppearance() {
        NSApp.appearance = appearance == "light" ? NSAppearance(named: .aqua)
            : appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
    }
}

private struct DayCell: View {
    let day: DayInfo
    let annotation: Annotation?
    let holiday: HolidayDay?
    let isToday: Bool
    let isSelected: Bool
    let isInMonth: Bool
    let accent: Color
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var annotationColor: Color {
        guard isInMonth else { return .secondary }
        guard let annotation else { return .secondary }
        if annotation.kind == .solarTerm {
            return colorScheme == .dark ? Color(red: 0.48, green: 0.74, blue: 0.55)
                : Color(red: 0.17, green: 0.43, blue: 0.25)
        }
        return colorScheme == .dark ? Color(red: 1, green: 0.47, blue: 0.40) : accent
    }

    private var hoverText: String {
        [annotation?.title ?? day.lunarFull, holiday?.detail].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = ["\(String(day.year))年\(day.month)月\(day.day)日", day.lunarFull]
        if let annotation { parts.append(annotation.title) }
        if let holiday { parts.append(holiday.detail) }
        if isToday { parts.append("今天") }
        return parts.joined(separator: "，")
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(day.day)")
                    .font(.system(size: 16, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Color.white : .primary)
                    .frame(width: 26, height: 26)
                    .background(isToday ? accent : .clear, in: Circle())
                Text(annotation?.shortTitle ?? day.lunarLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(annotationColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Color.primary.opacity(isSelected && !isToday ? 0.06 : hovering ? 0.04 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isSelected && !isToday {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let holiday {
                    Text(holiday.badge)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(holiday.isOffDay ? accent : Color.secondary)
                        .padding(.top, 1).padding(.trailing, 1)
                        .accessibilityHidden(true)
                }
            }
            .opacity(isInMonth ? 1 : 0.40)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(hoverText)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
