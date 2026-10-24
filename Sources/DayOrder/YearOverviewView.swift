import AppKit
import DayOrderCore
import SwiftUI

struct YearOverviewView: View {
    @ObservedObject var model: CalendarModel
    let firstWeekday: Int
    let blurEnabled: Bool
    @FocusState private var yearFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Button { model.showingYearOverview = false } label: {
                        Label("返回", systemImage: "chevron.left")
                    }
                    Spacer()
                    Text("年概览").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("今天") { model.goToToday() }
                }
                .buttonStyle(.bordered).controlSize(.small)
                if model.showingYearEntry {
                    HStack(spacing: 6) {
                        TextField("年份", text: $model.yearDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                            .focused($yearFocused)
                            .onSubmit { model.jumpToOverviewYear() }
                            .accessibilityLabel("年份，1901 至 2100")
                        Button("跳转") { model.jumpToOverviewYear() }
                            .disabled(model.validYearDraft == nil)
                        Spacer()
                        Button("取消") { model.showingYearEntry = false }
                    }
                    .controlSize(.small)
                    if model.validYearDraft == nil {
                        Text("请输入 1901–2100 之间的年份")
                            .font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
            }
            .padding(12)
            .background(CalendarSurface.chrome(blurEnabled: blurEnabled))
            YearCalendarScrollView(model: model, firstWeekday: firstWeekday)
                .background(CalendarSurface.content)
                .overlay(alignment: .top) { CalendarSurface.separator }
                .overlay(alignment: .bottom) { CalendarSurface.separator }
            Text("滚动浏览年份")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(CalendarSurface.chrome(blurEnabled: blurEnabled))
        }
        .frame(height: 430)
        .onChange(of: model.showingYearEntry) { yearFocused = model.showingYearEntry }
    }

}

private struct YearCalendarScrollView: NSViewRepresentable {
    @ObservedObject var model: CalendarModel
    let firstWeekday: Int

    func makeCoordinator() -> Coordinator { Coordinator(model: model, firstWeekday: firstWeekday) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("months"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.floatsGroupRows = true
        table.focusRingType = .none
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.firstWeekday != firstWeekday || coordinator.today != model.today
        coordinator.firstWeekday = firstWeekday
        coordinator.today = model.today
        guard let table = coordinator.table else { return }
        if changed {
            let visibleRows = table.rows(in: table.visibleRect)
            table.reloadData(forRowIndexes: IndexSet(integersIn: visibleRows.location..<NSMaxRange(visibleRows)),
                             columnIndexes: IndexSet(integer: 0))
        }
        if coordinator.scrollRevision != model.overviewScrollRevision {
            coordinator.scrollRevision = model.overviewScrollRevision
            table.layoutSubtreeIfNeeded()
            let year = model.overviewTarget / 100
            let month = model.overviewTarget % 100
            let row = (year - CalendarEngine.years.lowerBound) * 7 + 1 + (month - 1) / 2
            // 为悬浮年份标题保留空间，避免小月历标题被遮挡。
            let y = max(0, table.rect(ofRow: row).minY - Coordinator.headerHeight)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let headerHeight: CGFloat = 36
        let model: CalendarModel
        var firstWeekday: Int
        var today: Date
        var scrollRevision: Int?
        weak var table: NSTableView?
        private var monthLayouts: [Int: MiniMonthLayout] = [:]

        init(model: CalendarModel, firstWeekday: Int) {
            self.model = model
            self.firstWeekday = firstWeekday
            today = model.today
        }

        func numberOfRows(in tableView: NSTableView) -> Int { CalendarEngine.years.count * 7 }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            row % 7 == 0 ? Self.headerHeight : 136
        }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { row % 7 == 0 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let year = CalendarEngine.years.lowerBound + row / 7
            let index = row % 7
            if index == 0 {
                let identifier = NSUserInterfaceItemIdentifier("year")
                let header = tableView.makeView(withIdentifier: identifier, owner: nil) as? YearHeaderView
                    ?? YearHeaderView(frame: .zero)
                header.identifier = identifier
                header.configure(year: year) { [weak model] in model?.editOverviewYear(year) }
                return header
            }
            let month = (index - 1) * 2 + 1
            let identifier = NSUserInterfaceItemIdentifier("monthPair")
            let pair = tableView.makeView(withIdentifier: identifier, owner: nil) as? MonthPairView
                ?? MonthPairView(frame: .zero)
            pair.identifier = identifier
            let current = model.engine.calendar.dateComponents([.year, .month, .day], from: today)
            pair.configure(left: layout(year: year, month: month), right: layout(year: year, month: month + 1),
                           firstWeekday: firstWeekday, today: current) { [weak model] selectedMonth in
                model?.jumpToMonth(selectedMonth, year: year)
            }
            return pair
        }

        private func layout(year: Int, month: Int) -> MiniMonthLayout {
            let key = year * 100 + month
            if let layout = monthLayouts[key] { return layout }
            let calendar = model.engine.calendar
            let start = model.engine.date(year, month, 1)
            let layout = MiniMonthLayout(year: year, month: month,
                                         dayCount: calendar.range(of: .day, in: .month, for: start)!.count,
                                         startingWeekday: calendar.component(.weekday, from: start))
            monthLayouts[key] = layout
            return layout
        }
    }
}
