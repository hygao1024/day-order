import AppKit
import DayOrderCore
import SwiftUI

struct CalendarView: View {
    @ObservedObject var model: CalendarModel
    @FocusState private var yearFieldFocused: Bool
    @AppStorage("showTraditional") private var showTraditional = true
    @AppStorage("showCivil") private var showCivil = true
    @AppStorage("showWestern") private var showWestern = true
    @AppStorage("showWorldDays") private var showWorldDays = true
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
                settings
            } else {
                calendar
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial)
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .onAppear(perform: applyAppearance)
        .onChange(of: appearance) { applyAppearance() }
        .onChange(of: menuBarDisplay) { updateMenuBar() }
        .onChange(of: menuBarDateFormat) { updateMenuBar() }
        .onExitCommand {
            if model.showingMonthPicker { model.showingMonthPicker = false }
            else if model.showingSettings { model.showingSettings = false }
            else { dismiss() }
        }
    }

    private var calendar: some View {
        let month = model.engine.info(for: model.month)
        let days = model.engine.monthDays(containing: model.month, firstWeekday: effectiveWeekday)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if model.showingMonthPicker { model.showingMonthPicker = false }
                    else { model.openMonthPicker() }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(String(month.year))年\(month.month)月")
                            .font(.system(size: 16, weight: .semibold))
                        Image(systemName: model.showingMonthPicker ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("选择年份和月份")
                .accessibilityLabel("选择年月，当前\(String(month.year))年\(month.month)月")
                Spacer(minLength: 0)
                Button { model.moveMonth(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 12, height: 18)
                }
                .disabled(model.showingMonthPicker || !model.canMoveMonth(-1))
                .help("上个月（Page Up）")
                .accessibilityLabel("上个月")
                Button { model.goToToday() } label: {
                    Text("今天").frame(height: 18)
                }
                .help("回到今天（Home）")
                Button { model.moveMonth(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 12, height: 18)
                }
                .disabled(model.showingMonthPicker || !model.canMoveMonth(1))
                .help("下个月（Page Down）")
                .accessibilityLabel("下个月")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.bottom, 12)

            if model.showingMonthPicker {
                monthPicker
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<7) { index in
                        Text(weekdays[(effectiveWeekday - 1 + index) % 7])
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)
                .padding(.bottom, 6)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
                    ForEach(days) { day in
                        DayCell(day: day, annotation: visibleAnnotations(day).first,
                                isToday: day.date == model.today, isSelected: day.date == model.selection,
                                isInMonth: day.month == month.month, accent: accent) {
                            model.select(day.date)
                        }
                        .disabled(!model.engine.isSupported(day.date))
                    }
                }
                .padding(.bottom, 10)
                Divider()
                detail.padding(.top, 8)
            }
        }
    }

    private var monthPicker: some View {
        let current = model.engine.info(for: model.month)
        let year = model.validMonthPickerYear
        return VStack(spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    if let year { model.monthPickerYear = String(year - 1) }
                } label: {
                    Image(systemName: "chevron.left").frame(width: 18, height: 18)
                }
                .disabled(year == nil || year == CalendarEngine.years.lowerBound)
                .accessibilityLabel("上一年")
                Spacer()
                TextField("年份", text: $model.monthPickerYear)
                    .font(.system(size: 16, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .focused($yearFieldFocused)
                    .accessibilityLabel("年份，1901 至 2100")
                Text("年").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let year { model.monthPickerYear = String(year + 1) }
                } label: {
                    Image(systemName: "chevron.right").frame(width: 18, height: 18)
                }
                .disabled(year == nil || year == CalendarEngine.years.upperBound)
                .accessibilityLabel("下一年")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Text(year == nil ? "请输入 1901–2100 之间的年份" : "输入年份，然后选择月份")
                .font(.system(size: 11))
                .foregroundStyle(year == nil ? Color.red : Color.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    Button {
                        if let year { model.jumpToMonth(month, year: year) }
                    } label: {
                        Text("\(month)月")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(Color.primary.opacity(year == current.year && month == current.month ? 0.12 : 0.04),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(year == nil)
                }
            }
            HStack {
                Spacer()
                Button("取消") { model.showingMonthPicker = false }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .onAppear { yearFieldFocused = true }
    }

    private var detail: some View {
        let day = model.engine.info(for: model.selection)
        let prefix = model.selection == model.today ? "今天 · " : ""
        let annotations = visibleAnnotations(day).map(\.title)
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
            Text(([day.lunarFull] + annotations).joined(separator: " · "))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.showingSettings = false } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
                Text("设置").font(.headline)
                Spacer()
                Text("返回").hidden().accessibilityHidden(true)
            }
            Divider()
            Picker("菜单栏显示", selection: $menuBarDisplay) {
                Text("图标和日期").tag(MenuBarDisplay.iconAndDate.rawValue)
                Text("仅日期").tag(MenuBarDisplay.dateOnly.rawValue)
                Text("仅图标").tag(MenuBarDisplay.iconOnly.rawValue)
            }
            if menuBarDisplay != MenuBarDisplay.iconOnly.rawValue {
                Picker("日期格式", selection: $menuBarDateFormat) {
                    Text("月日＋星期").tag(MenuBarDateFormat.monthDayWeekday.rawValue)
                    Text("年月日").tag(MenuBarDateFormat.yearMonthDay.rawValue)
                    Text("年月日＋星期").tag(MenuBarDateFormat.yearMonthDayWeekday.rawValue)
                    Text("数字日期").tag(MenuBarDateFormat.numericDate.rawValue)
                }
            }
            Divider()
            Toggle("中国传统节日", isOn: $showTraditional)
            Toggle("中国公历节日", isOn: $showCivil)
            Toggle("西方节日", isOn: $showWestern)
            Toggle("世界日", isOn: $showWorldDays)
            Toggle("二十四节气", isOn: $showSolarTerms)
            Picker("每周开始于", selection: $firstWeekday) {
                Text("星期一").tag(2)
                Text("星期日").tag(1)
            }
            Picker("外观", selection: $appearance) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("日序 DayOrder").font(.headline)
                Text("日期、节气、节日，一眼有序。")
                Text("支持 1901–2100 年。农历和节气按中国历法日期标注；节日不代表法定休假。")
                Text("农历与节气数据：香港天文台")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("退出日序") { NSApplication.shared.terminate(nil) }
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.switch)
        .controlSize(.small)
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
            .frame(height: 44)
            .background(Color.primary.opacity(isSelected ? 0.08 : hovering ? 0.04 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .opacity(isInMonth ? 1 : 0.40)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(annotation?.title ?? day.lunarFull)
        .accessibilityLabel("\(String(day.year))年\(day.month)月\(day.day)日，\(day.lunarFull)" +
                            (annotation.map { "，" + $0.title } ?? "") + (isToday ? "，今天" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
