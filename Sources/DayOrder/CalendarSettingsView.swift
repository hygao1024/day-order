import AppKit
import DayOrderCore
import SwiftUI

struct CalendarSettingsView: View {
    @ObservedObject var model: CalendarModel
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var appUpdater: AppUpdater
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                generalSection
                displaySection
                calendarSection
                holidaySection
                updateSection
                about
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.never)
        .font(.system(size: 12))
        .controlSize(.small)
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    var header: some View {
        HStack {
            Text("设置").font(.system(size: 16, weight: .semibold))
            Spacer()
            Button { model.showingSettings = false } label: {
                Label("日历", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
            }
            .buttonStyle(SettingsCapsuleButtonStyle())
            .help("返回日历")
            .accessibilityLabel("返回日历")
        }
        .padding(12)
    }

    private var generalSection: some View {
        group("通用") {
            toggle("开机自启", isOn: Binding(get: { launchAtLogin.isOn }, set: { launchAtLogin.setEnabled($0) }))
                .disabled(!launchAtLogin.canChange)
            VStack(alignment: .leading, spacing: 6) {
                Text(launchAtLogin.explanation)
                if let message = launchAtLogin.errorMessage {
                    Text(message).foregroundStyle(.red)
                }
                if launchAtLogin.status == .requiresApproval || launchAtLogin.errorMessage != nil {
                    Button("打开系统登录项设置") { launchAtLogin.openSystemSettings() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
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
                .help("开启后模糊弹窗外围背景；关闭后使用实色背景")
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
                    Button {
                        model.updateHolidays(year: model.displayedYear)
                    } label: {
                        Text(model.holidayUpdatingYear == nil ? "更新\(String(model.displayedYear))年" : "更新中…")
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                    }
                    .font(.system(size: 11))
                    .buttonStyle(SettingsCapsuleButtonStyle())
                    .disabled(model.holidayUpdatingYear != nil || !HolidayYear.supportedYears.contains(model.displayedYear))
                }
                if let message = model.holidayUpdateMessages[model.displayedYear] {
                    Text(message)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var updateSection: some View {
        group("软件更新") {
            toggle("自动检查更新", isOn: Binding(get: { appUpdater.automaticallyChecks },
                                               set: { appUpdater.setAutomaticallyChecks($0) }))
                .disabled(!appUpdater.isAvailable)
            separator
            toggle("自动下载并安装", isOn: Binding(get: { appUpdater.automaticallyInstalls },
                                               set: { appUpdater.setAutomaticallyInstalls($0) }))
                .disabled(!appUpdater.isAvailable || !appUpdater.automaticallyChecks)
            Text("仅更新正式版本。开启自动安装后，后台下载并在退出时安装，也可选择立即安装并重启。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            row("GitHub · Apple 芯片") {
                Button { appUpdater.checkForUpdates() } label: {
                    Text("检查更新…")
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                }
                    .buttonStyle(SettingsCapsuleButtonStyle())
                    .disabled(!appUpdater.canCheck)
                    .accessibilityLabel("检查软件更新")
            }
            if let message = appUpdater.message {
                Text(message)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        }
    }

    private var about: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text("版本：\(version ?? "开发版本")")
                Text("支持 1901–2100 年。农历和节气按中国历法日期标注；节日名称不代表法定休假。")
                Text("农历与节气：香港天文台")
                Text("放假与调休：holiday-cn")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        } label: {
            Text("关于日序").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            Text("日序").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("退出日序") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .frame(height: 42)
        .padding(.horizontal, 12)
    }

    private var separator: some View {
        Divider().opacity(0.45)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(spacing: 0, content: content)
        }
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 30)
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
            HStack(spacing: 5) {
                Text(selectedTitle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.primary.opacity(0.045), in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5) }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .clipShape(Capsule())
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        row(title) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // 绑定同步时 NSSwitch 的隐式动画会同步重绘窗口，重入尚未结束的 SwiftUI 布局。
                .transaction { $0.disablesAnimations = true }
                .accessibilityLabel(title)
        }
    }
}

private struct SettingsCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .opacity(isEnabled ? 1 : 0.5)
            .background(.primary.opacity(isEnabled && configuration.isPressed ? 0.12 : isEnabled && isHovered ? 0.08 : 0.045), in: Capsule())
            .overlay { Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5) }
            .contentShape(Capsule())
            .clipShape(Capsule())
            .onHover { isHovered = $0 }
    }
}
