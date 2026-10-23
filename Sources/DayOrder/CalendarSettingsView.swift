import AppKit
import DayOrderCore
import SwiftUI

struct CalendarSettingsView: View {
    @ObservedObject var model: CalendarModel
    @Binding var menuBarDisplay: String
    @Binding var menuBarDateFormat: String
    @Binding var appearance: String
    @Binding var blurEnabled: Bool
    @Binding var firstWeekday: Int
    @Binding var showTraditional: Bool
    @Binding var showCivil: Bool
    @Binding var showWestern: Bool
    @Binding var showWorldDays: Bool
    @Binding var showSolarTerms: Bool
    @Binding var showHolidaySchedule: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    displaySection
                    calendarSection
                    holidaySection
                    about
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 1)
            }
            .frame(height: 410)
            .scrollIndicators(.automatic)
            footer
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    private var header: some View {
        HStack {
            Button { model.showingSettings = false } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("返回日历")
            .accessibilityLabel("返回日历")
            Spacer()
            Text("设置").font(.system(size: 14, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 28, height: 28).accessibilityHidden(true)
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var displaySection: some View {
        group("显示") {
            row("菜单栏") {
                choice("菜单栏显示", selection: $menuBarDisplay, options: [
                    ("图标和日期", MenuBarDisplay.iconAndDate.rawValue),
                    ("仅日期", MenuBarDisplay.dateOnly.rawValue),
                    ("仅图标", MenuBarDisplay.iconOnly.rawValue)
                ])
            }
            if menuBarDisplay != MenuBarDisplay.iconOnly.rawValue {
                separator
                row("日期格式") {
                    choice("日期格式", selection: $menuBarDateFormat, options: [
                        ("月日＋星期", MenuBarDateFormat.monthDayWeekday.rawValue),
                        ("年月日", MenuBarDateFormat.yearMonthDay.rawValue),
                        ("年月日＋星期", MenuBarDateFormat.yearMonthDayWeekday.rawValue),
                        ("数字日期", MenuBarDateFormat.numericDate.rawValue)
                    ])
                }
            }
            separator
            row("外观") {
                choice("外观", selection: $appearance, options: [
                    ("跟随系统", "system"), ("浅色", "light"), ("深色", "dark")
                ])
            }
            separator
            toggle("毛玻璃效果", isOn: $blurEnabled)
                .help("开启后模糊日历上下区域的背景；关闭后使用实色背景")
        }
    }

    private var calendarSection: some View {
        group("日历内容") {
            row("每周开始于") {
                choice("每周开始于", selection: $firstWeekday, options: [("星期一", 2), ("星期日", 1)])
            }
            separator
            toggle("中国传统节日", isOn: $showTraditional)
            separator
            toggle("中国公历节日", isOn: $showCivil)
            separator
            toggle("西方节日", isOn: $showWestern)
            separator
            toggle("世界日", isOn: $showWorldDays)
            separator
            toggle("二十四节气", isOn: $showSolarTerms)
        }
    }

    private var holidaySection: some View {
        group("放假安排") {
            toggle("放假与调休", isOn: $showHolidaySchedule)
            if showHolidaySchedule {
                separator
                row("中国大陆") {
                    Button(model.holidayUpdatingYear == nil ? "更新\(String(model.displayedYear))年" : "更新中…") {
                        model.updateHolidays(year: model.displayedYear)
                    }
                    .disabled(model.holidayUpdatingYear != nil || !HolidayYear.supportedYears.contains(model.displayedYear))
                }
                if let message = model.holidayUpdateMessages[model.displayedYear] {
                    Text(message)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
        }
    }

    private var about: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("支持 1901–2100 年。农历和节气按中国历法日期标注；节日名称不代表法定休假。")
                Text("农历与节气：香港天文台")
                Text("放假与调休：holiday-cn")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        } label: {
            Text("关于日序").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            Text("日序").fontWeight(.medium)
            Spacer()
            Button("退出日序") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4).padding(.top, 10)
        .overlay(alignment: .top) { Divider() }
    }

    private var separator: some View {
        Divider().padding(.horizontal, 12).opacity(0.55)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(spacing: 0, content: content)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65),
                            in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5)
                }
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 12)
    }

    private func choice<Value: Hashable>(_ title: String, selection: Binding<Value>,
                                         options: [(String, Value)]) -> some View {
        let selectedTitle = options.first { $0.1 == selection.wrappedValue }?.0 ?? options[0].0
        return Menu {
            Picker(title, selection: selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].0).tag(options[index].1)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(selectedTitle)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }
}
