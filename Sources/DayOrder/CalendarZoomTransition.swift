import AppKit
import Combine
import DayOrderCore
import QuartzCore
import SwiftUI

struct CalendarZoomAnchor {
    let day: Int
    let frame: NSRect
    let fontSize: CGFloat
    let weight: CGFloat
    let color: NSColor
    let circle: Bool
}

struct CalendarZoomCaption {
    let image: NSImage
    let frame: NSRect
}

@MainActor
protocol CalendarZoomParticipant: NSView {
    var zoomHiddenDays: Set<Int> { get set }
    func zoomAnchors(month: Int, in root: NSView) -> [CalendarZoomAnchor]
    func zoomCaption(month: Int, in root: NSView) -> CalendarZoomCaption?
}

extension CalendarZoomParticipant {
    func zoomCaption(month: Int, in root: NSView) -> CalendarZoomCaption? { nil }
}

@MainActor
enum CalendarSnapshotImage {
    #if DEBUG
    static var timelineBitmapCount = 0
    #endif
    static func rasterized(_ image: NSImage, scale: CGFloat) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(image.size.width * scale)),
            pixelsHigh: Int(ceil(image.size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previous }
        context.imageInterpolation = .high
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero,
                   operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        bitmap.size = image.size
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        return result
    }

    static func capture(_ view: NSView, in rect: NSRect) -> NSImage? {
        #if DEBUG
        if let scroll = view as? NSScrollView,
           scroll.documentView?.identifier?.rawValue == "calendarTimeline" { timelineBitmapCount += 1 }
        #endif
        guard rect.width > 0, rect.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }
}

// 偏移保留日期格在窗口像素网格上的相位，移动时不再缩放位图。
private struct CalendarModeImage {
    let image: NSImage
    let offset: CGPoint

    func draw(at origin: CGPoint, scale: CGFloat, operation: NSCompositingOperation, fraction: CGFloat) {
        let aligned = CGPoint(x: ((origin.x + offset.x) * scale).rounded() / scale,
                              y: ((origin.y + offset.y) * scale).rounded() / scale)
        image.draw(in: CGRect(origin: aligned, size: image.size), from: .zero,
                   operation: operation, fraction: fraction, respectFlipped: true, hints: nil)
    }
}

private struct CalendarModeElement {
    let id: Int
    let frame: CGRect
    let image: CalendarModeImage?
    var markers: [CalendarEventMarker] = []
}

private struct CalendarZoomSnapshot {
    var content: NSImage
    let size: NSSize
    let card: NSRect
    let anchors: [CalendarZoomAnchor]
    let month: Int
    var overviewMonths: [Int: NSRect] = [:]
    var canvasContent: NSImage?
    var captions: [CalendarZoomCaption] = []
    var backingScale: CGFloat = 2
    var modeElements: [CalendarModeElement]?
    var isOverview: Bool { !overviewMonths.isEmpty }
    #if DEBUG
    var suppressedCircleInk = 0
    @MainActor static var modeCaptureCount = 0
    @MainActor static var modeRowBitmapCount = 0
    @MainActor static var modePDFCount = 0
    @MainActor static var modeCaptureMilliseconds = 0.0
    #endif

    @MainActor static func capture(_ root: NSView, month: Int, capturesModeElements: Bool = false,
                                  modeOverflow: CGFloat = 0) -> Self? {
        #if DEBUG
        let captureStarted = ProcessInfo.processInfo.systemUptime
        if capturesModeElements { modeCaptureCount += 1 }
        defer {
            if capturesModeElements { modeCaptureMilliseconds += (ProcessInfo.processInfo.systemUptime - captureStarted) * 1000 }
        }
        #endif
        let views = descendants(root)
        guard let scroll = views.compactMap({ $0 as? NSScrollView }).first else { return nil }
        if !capturesModeElements, scroll.documentView?.identifier?.rawValue == "calendarTimeline" {
            return captureMonth(scroll, root: root, month: month)
        }
        let card = root.convert(scroll.bounds, from: scroll)
        let headers = views.compactMap { $0 as? YearHeaderView }.filter { !$0.visibleRect.isEmpty }
            .map { root.convert($0.visibleRect, from: $0) }
        let participants = views.compactMap { $0 as? any CalendarZoomParticipant }.map { view in
            (view, view.zoomAnchors(month: month, in: root).filter { anchor in
                !headers.contains { $0.intersects(anchor.frame) }
            })
        }.filter { !$0.1.isEmpty }
        let anchors = participants.flatMap(\.1)
        let months = views.compactMap { $0 as? MonthPairView }.flatMap { $0.zoomMonthFrames(in: root) }
        if capturesModeElements, let mode = captureModeElements(scroll, root: root, overflow: modeOverflow) {
            var snapshot = Self(content: mode.content, size: root.bounds.size, card: card, anchors: anchors, month: month,
                                backingScale: root.window?.backingScaleFactor ?? 2)
            snapshot.modeElements = mode.elements
            return snapshot
        }
        guard let content = CalendarSnapshotImage.capture(scroll, in: scroll.bounds) else { return nil }
        let captions = participants.compactMap { $0.0.zoomCaption(month: month, in: root) }
        participants.forEach { view, anchors in view.zoomHiddenDays = Set(anchors.map(\.day)); view.needsDisplay = true }
        defer { participants.forEach { view, _ in view.zoomHiddenDays = []; view.needsDisplay = true } }
        // 画布快照不包含焦点日期；正常显示和短淡化仍使用完整正文。
        #if DEBUG
        if capturesModeElements, !participants.isEmpty { modePDFCount += 1 }
        #endif
        let canvasContent = participants.isEmpty ? nil : NSImage(data: scroll.dataWithPDF(inside: scroll.bounds))
        var snapshot = Self(content: content, size: root.bounds.size, card: card, anchors: anchors, month: month,
                            overviewMonths: Dictionary(months, uniquingKeysWith: { first, _ in first }),
                            canvasContent: canvasContent, captions: captions,
                            backingScale: root.window?.backingScaleFactor ?? 2)
        #if DEBUG
        for anchor in anchors where anchor.circle {
            let probe = CGRect(x: anchor.frame.midX - 3, y: anchor.frame.midY - 3, width: 6, height: 6)
            if let image = CalendarSnapshotImage.capture(scroll, in: scroll.convert(probe, from: root)),
               let bitmap = image.representations.first as? NSBitmapImageRep {
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                            snapshot.suppressedCircleInk += 1
                        }
                    }
                }
            }
        }
        #endif
        return snapshot
    }

    @MainActor private static func captureMonth(_ scroll: NSScrollView, root: NSView, month: Int) -> Self? {
        guard let table = scroll.documentView as? NSTableView,
              let coordinator = table.delegate as? CalendarTimelineView.Coordinator else { return nil }
        let viewport = table.convert(CGRect(origin: scroll.contentView.bounds.origin, size: scroll.bounds.size),
                                     from: scroll.contentView)
        let range = table.rows(in: viewport)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var rows: [NSView] = []
        for row in range.location..<NSMaxRange(range) {
            guard table.rect(ofRow: row).intersection(viewport).height > 0.01 else { continue }
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
            if let week = view as? CalendarWeekView { coordinator.refreshEvents(in: week, row: row) }
            view.layoutSubtreeIfNeeded()
            rows.append(view)
        }
        let card = root.convert(scroll.bounds, from: scroll)
        let scale = root.window?.backingScaleFactor ?? 2
        // 按完整逻辑视口准备并逐周采集，旧年视图窗口不能裁掉月历末周。
        func image(vector: Bool) -> NSImage? {
            var parts: [(NSImage, CGRect)] = []
            for row in rows {
                let captured = vector ? NSImage(data: row.dataWithPDF(inside: row.bounds))
                    : CalendarSnapshotImage.capture(row, in: row.bounds)
                guard let captured else { return nil }
                let frame = root.convert(row.bounds, from: row).offsetBy(dx: -card.minX, dy: -card.minY)
                parts.append((captured, frame))
            }
            return NSImage(size: card.size, flipped: true) { _ in
                for (image, frame) in parts {
                    image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                               respectFlipped: true, hints: nil)
                }
                return true
            }
        }
        guard let full = image(vector: false), let content = CalendarSnapshotImage.rasterized(full, scale: scale) else { return nil }
        let participants = rows.flatMap { $0.subviews.compactMap { $0 as? CalendarDayButton } }.map { button in
            (button, button.zoomAnchors(month: month, in: root))
        }.filter { !$0.1.isEmpty }
        let hidden = participants.map { $0.0.zoomHiddenDays }
        participants.forEach { button, anchors in button.zoomHiddenDays = Set(anchors.map(\.day)); button.needsDisplay = true }
        defer {
            for ((button, _), days) in zip(participants, hidden) {
                button.zoomHiddenDays = days
                button.needsDisplay = true
            }
        }
        guard let canvas = image(vector: true) else { return nil }
        let anchors = participants.flatMap(\.1)
        var snapshot = Self(content: content, size: root.bounds.size, card: card, anchors: anchors,
                            month: month, canvasContent: canvas, backingScale: scale)
        #if DEBUG
        if anchors.contains(where: \.circle),
           let bitmap = CalendarSnapshotImage.rasterized(canvas, scale: scale)?.representations.first as? NSBitmapImageRep {
            for anchor in anchors where anchor.circle {
                let center = CGPoint(x: anchor.frame.midX - card.minX, y: anchor.frame.midY - card.minY)
                let probe = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
                    .intersection(CGRect(origin: .zero, size: card.size))
                guard !probe.isNull else { continue }
                for y in Int(probe.minY * scale)..<Int(probe.maxY * scale) {
                    for x in Int(probe.minX * scale)..<Int(probe.maxX * scale) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           color.redComponent > 0.6, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                            snapshot.suppressedCircleInk += 1
                        }
                    }
                }
            }
        }
        #endif
        return snapshot
    }

    @MainActor private static func captureModeElements(_ scroll: NSScrollView, root: NSView, overflow: CGFloat)
        -> (elements: [CalendarModeElement], content: NSImage)? {
        guard let table = scroll.documentView as? NSTableView, table.identifier?.rawValue == "calendarTimeline" else { return nil }
        // 目标正文可能高于动画起点窗口；端点取逻辑视口，不能被旧窗口裁掉末周。
        let logicalViewport = CGRect(origin: scroll.contentView.bounds.origin, size: scroll.bounds.size)
        // 展开使周行经过可视边缘；两端都保留最大详情高度内的行，离场由卡片裁切。
        let viewport = table.convert(logicalViewport, from: scroll.contentView).insetBy(dx: 0, dy: -overflow)
        let rows = table.rows(in: viewport)
        var elements: [CalendarModeElement] = []
        var rowImages: [(NSImage, CGRect)] = []
        for row in rows.location..<NSMaxRange(rows) {
            let intersection = table.rect(ofRow: row).intersection(viewport)
            guard !intersection.isNull, intersection.height > 0.01 else { continue }
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            // 末周可能尚被旧窗口裁掉，必须按当前模式刷新，不能沿用复用行的旧按钮高度。
            if let week = view as? CalendarWeekView,
               let coordinator = table.delegate as? CalendarTimelineView.Coordinator {
                coordinator.refreshEvents(in: week, row: row)
            }
            view.layoutSubtreeIfNeeded()
            let frame = root.convert(view.bounds, from: view)
            if view is CalendarWeekView {
                let buttons = view.subviews.compactMap { $0 as? CalendarDayButton }.filter { !$0.isHidden }
                let area = root.backingAlignedRect(frame, options: .alignAllEdgesOutward)
                let bitmap: NSBitmapImageRep? = {
                    let hidden = buttons.map(\.snapshotHidesEventMarkers)
                    buttons.forEach { $0.snapshotHidesEventMarkers = true; $0.needsDisplay = true }
                    defer {
                        for (button, value) in zip(buttons, hidden) {
                            button.snapshotHidesEventMarkers = value
                            button.needsDisplay = true
                        }
                    }
                    let local = view.convert(area, from: root)
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: local) else { return nil }
                    view.cacheDisplay(in: local, to: bitmap)
                    return bitmap
                }()
                guard let bitmap, let weekImage = bitmap.cgImage else { return nil }
                rowImages.append((NSImage(cgImage: weekImage, size: area.size), area))
                #if DEBUG
                modeRowBitmapCount += 1
                #endif
                let scaleX = CGFloat(bitmap.pixelsWide) / area.width
                let scaleY = CGFloat(bitmap.pixelsHigh) / area.height
                // 一次周行采样后裁切，保留每格在根视图像素网格上的原始偏移。
                for (column, button) in view.subviews.compactMap({ $0 as? CalendarDayButton }).enumerated()
                    where !button.isHidden {
                    let buttonFrame = root.convert(button.bounds, from: button)
                    let cell = root.backingAlignedRect(buttonFrame, options: .alignAllEdgesOutward)
                    let pixels = CGRect(x: ((cell.minX - area.minX) * scaleX).rounded(),
                                        y: ((cell.minY - area.minY) * scaleY).rounded(),
                                        width: (cell.width * scaleX).rounded(), height: (cell.height * scaleY).rounded())
                    guard let cropped = weekImage.cropping(to: pixels) else { return nil }
                    let image = NSImage(cgImage: cropped, size: cell.size)
                    elements.append(CalendarModeElement(id: row * 8 + column, frame: buttonFrame,
                        image: CalendarModeImage(image: image,
                            offset: CGPoint(x: cell.minX - buttonFrame.minX, y: cell.minY - buttonFrame.minY)),
                        markers: button.eventMarkers))
                }
                if let week = view as? CalendarWeekView, !week.agendaView.isHidden {
                    let agendaFrame = root.convert(week.agendaView.bounds, from: week.agendaView)
                    let aligned = root.backingAlignedRect(agendaFrame, options: .alignAllEdgesOutward)
                    let pixels = CGRect(x: ((aligned.minX - area.minX) * scaleX).rounded(),
                                        y: ((aligned.minY - area.minY) * scaleY).rounded(),
                                        width: (aligned.width * scaleX).rounded(), height: (aligned.height * scaleY).rounded())
                    guard let cropped = weekImage.cropping(to: pixels) else { return nil }
                    // 负标识属于周内详情，不占用七列日期和周分隔线的既有身份。
                    elements.append(CalendarModeElement(id: -(row + 1), frame: agendaFrame,
                        image: CalendarModeImage(image: NSImage(cgImage: cropped, size: aligned.size),
                            offset: CGPoint(x: aligned.minX - agendaFrame.minX, y: aligned.minY - agendaFrame.minY))))
                }
                let inset = CalendarTimelineView.contentInset
                elements.append(CalendarModeElement(id: row * 8 + 7,
                    frame: CGRect(x: frame.minX + inset, y: frame.maxY - 0.5,
                                  width: frame.width - 2 * inset, height: 0.5), image: nil))
            } else {
                let area = root.backingAlignedRect(frame, options: .alignAllEdgesOutward)
                guard let image = CalendarSnapshotImage.capture(view, in: view.convert(area, from: root)) else { return nil }
                rowImages.append((image, area))
                elements.append(CalendarModeElement(id: row * 8 + 7, frame: frame,
                    image: CalendarModeImage(image: image,
                        offset: CGPoint(x: area.minX - frame.minX, y: area.minY - frame.minY))))
            }
        }
        guard !elements.isEmpty else { return nil }
        let card = root.convert(scroll.bounds, from: scroll)
        let scale = root.window?.backingScaleFactor ?? 2
        let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // 冻结画面复用完整周行位图，再合成标记；无需重绘原生视图或逐格拼接。
        let composed = NSImage(size: card.size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: -card.minX, y: -card.minY)
            for (image, frame) in rowImages {
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: true, hints: nil)
            }
            for element in elements where !element.markers.isEmpty {
                context.saveGState()
                context.clip(to: element.frame)
                context.translateBy(x: element.frame.minX, y: element.frame.minY)
                for marker in element.markers {
                    CalendarEventDrawing.draw(marker: marker, style: marker.style, dark: dark)
                }
                context.restoreGState()
            }
            return true
        }
        guard let content = CalendarSnapshotImage.rasterized(composed, scale: scale) else { return nil }
        return (elements, content)
    }

    @MainActor static func eventMarkerTargets(_ root: NSView) -> [Int: [CalendarEventMarker]] {
        guard let table = descendants(root).compactMap({ $0 as? NSTableView })
            .first(where: { $0.identifier?.rawValue == "calendarTimeline" }),
              let scroll = table.enclosingScrollView,
              let coordinator = table.delegate as? CalendarTimelineView.Coordinator else { return [:] }
        let viewport = table.convert(CGRect(origin: scroll.contentView.bounds.origin, size: scroll.bounds.size), from: scroll.contentView)
        let rows = table.rows(in: viewport)
        var targets: [Int: [CalendarEventMarker]] = [:]
        for row in rows.location..<NSMaxRange(rows) {
            guard let week = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? CalendarWeekView else { continue }
            coordinator.refreshEvents(in: week, row: row)
            week.layoutSubtreeIfNeeded()
            for (column, button) in week.subviews.compactMap({ $0 as? CalendarDayButton }).enumerated()
                where !button.isHidden { targets[row * 8 + column] = button.eventMarkers }
        }
        return targets
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor
final class CalendarHostingController: NSHostingController<AnyView> {
    var contentSizeChanged: ((NSSize) -> Void)?
    private var lastSize = NSSize.zero
    private var sizeNotificationPending = false

    override func viewDidLayout() {
        super.viewDidLayout()
        let size = view.fittingSize
        guard size != lastSize else { return }
        lastSize = size
        guard !sizeNotificationPending else { return }
        sizeNotificationPending = true
        // 窗口改尺寸会同步触发布局；退出当前布局栈后只交付最新测量值。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            sizeNotificationPending = false
            contentSizeChanged?(lastSize)
        }
    }
}

// 展示层拥有短暂的快照、尺寸插值与取消；不写日期选择或滚动位置。
@MainActor
final class CalendarPresentationController: NSViewController {
    var contentSizeChanged: ((NSSize) -> Void)?
    override var preferredContentSize: NSSize {
        get { super.preferredContentSize }
        set {
            // 先统一控制器和窗口的高度，避免 AppKit 分别取整后相差一个点。
            let size = NSSize(width: newValue.width, height: ceil(newValue.height))
            guard size != super.preferredContentSize else { return }
            super.preferredContentSize = size
            contentSizeChanged?(size)
        }
    }
    let host: CalendarHostingController
    private let model: CalendarModel
    private let defaults: UserDefaults
    private var subscriptions: Set<AnyCancellable> = []
    private var preparation: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var lastFrameTime = 0.0
    private var serial = 0
    private var overlay: CalendarZoomOverlay?
    private var transitioningCalendarLayout = false
    private var presentedAgendaEvents: [CalendarEvent] = []
    let material = NSVisualEffectView()
    private weak var transitioningShell: CalendarShellView?
    private var targetSize = NSSize(width: 320, height: 430)
    private(set) var progress: CGFloat = 1
    private(set) var elapsedFraction: CGFloat = 1
    var isTransitioning: Bool { overlay != nil }
    var transitionView: NSView? { overlay }
    #if DEBUG
    var reduceMotionOverride: Bool?
    var controlsAnimationClock = false
    var hasActiveFrameDriver: Bool { displayLink != nil }
    var activeFrameRateRange: CAFrameRateRange? { displayLink?.preferredFrameRateRange }
    private(set) var driverCallbackCount = 0
    private(set) var displayTimestamps: [Double] = []
    private(set) var preparationMilliseconds = 0.0
    private(set) var preparationPhases: [String: Double] = [:]
    private(set) var frameMilliseconds: [Double] = []
    private(set) var drawingMilliseconds: [Double] = []
    var matchedDayCount: Int { overlay?.matchedDayCount ?? 0 }
    var movingDayFrame: NSRect? { overlay?.movingDayFrame }
    var movingCardFrame: NSRect? { overlay?.cardFrame }
    var movingCardVelocity: NSRect? { overlay?.cardVelocity }
    var canvasSample: [String: Double]? { overlay?.canvasSample }
    var eventModeSample: [String: Double]? { overlay?.modeSample }
    var eventModeCells: [Int: [String: Double]] { overlay?.modeCells ?? [:] }
    var eventMarkerSample: [String: [String: Double]]? { overlay?.markerSample }
    var eventCaptureCounters: [String: Double] {
        ["snapshots": Double(CalendarZoomSnapshot.modeCaptureCount),
         "fullBitmaps": Double(CalendarSnapshotImage.timelineBitmapCount),
         "rows": Double(CalendarZoomSnapshot.modeRowBitmapCount),
         "pdfs": Double(CalendarZoomSnapshot.modePDFCount),
         "milliseconds": CalendarZoomSnapshot.modeCaptureMilliseconds]
    }
    private(set) var eventPreparationCount = 0
    private(set) var eventMarkerRefreshCount = 0
    private(set) var eventMarkerRefreshMilliseconds = 0.0
    private(set) var handoffDateError: CGFloat?
    var isPreparedForSampling: Bool { preparation == nil && overlay?.destination != nil }
    func sampleGeometry(deltaTime: Double) {
        precondition(isPreparedForSampling)
        displayLink?.invalidate()
        displayLink = nil
        applyFrame(deltaTime: deltaTime)
    }
    func finishGeometrySampling() { finishTransition() }
    var motionSeconds: Double { overlay?.elapsed ?? 0 }
    var outgoingOpacity: CGFloat { overlay.map { 1 - $0.contentFraction } ?? 0 }
    var incomingOpacity: CGFloat { overlay?.contentFraction ?? 1 }
    private(set) var retargetPositionError = 0.0
    private(set) var retargetVelocityError = 0.0
    private(set) var retargetCount = 0
    var shell: CalendarShellView? {
        descendants(host.view).compactMap { $0 as? CalendarShellView }.first
    }
    #endif

    init(host: CalendarHostingController, model: CalendarModel, defaults: UserDefaults) {
        self.host = host
        self.model = model
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
        addChild(host)
        _ = view
        host.sizingOptions = [.preferredContentSize]
        targetSize = host.view.fittingSize
        preferredContentSize = targetSize
        host.contentSizeChanged = { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            targetSize = size
            if !isTransitioning { preferredContentSize = size }
            view.needsLayout = true
        }
        model.$showingYearOverview.removeDuplicates().dropFirst().sink { [weak self] year in
            self?.prepare(.year(year))
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateMaterial() }
            .store(in: &subscriptions)
        model.$showingSettings.removeDuplicates().dropFirst().sink { [weak self] settings in
            self?.prepare(.settings(settings))
        }.store(in: &subscriptions)
        model.events.$mode.removeDuplicates().dropFirst().sink { [weak self] mode in
            guard let self, !model.showingSettings, !model.showingYearOverview else { return }
            prepare(.events(mode))
        }.store(in: &subscriptions)
        model.$agenda.removeDuplicates().dropFirst().sink { [weak self] value in
            guard let self else { return }
            presentedAgendaEvents = value.flatMap { model.events.days[$0.date] } ?? []
            guard model.events.mode != .hidden, !model.showingSettings, !model.showingYearOverview else { return }
            prepare(.agenda(value))
        }.store(in: &subscriptions)
        model.events.$revision.dropFirst().sink { [weak self] _ in
            guard let self, model.events.mode != .hidden else { return }
            if let agenda = model.agenda, !model.showingSettings, !model.showingYearOverview {
                let values = model.events.days[agenda.date] ?? []
                let changed = values != presentedAgendaEvents
                presentedAgendaEvents = values
                // 跨月查询可能只改变其他日期；屏幕外详情由真实表格更新，不启动离屏动画。
                let visible = descendants(host.view).contains { view in
                    view is CalendarDayAgendaView && !view.isHidden && !view.visibleRect.isEmpty
                }
                if changed && visible && model.calendarScrollAnimationSelection == nil {
                    prepare(.agenda(agenda))
                    return
                }
            }
            guard transitioningCalendarLayout else { return }
            // 正在准备的终点会采集最新事件；活动动画只更新标记，不重做底图和时钟。
            guard preparation == nil, let overlay else { return }
            #if DEBUG
            let refreshStarted = ProcessInfo.processInfo.systemUptime
            #endif
            let targets = CalendarZoomSnapshot.eventMarkerTargets(host.view)
            if overlay.refreshEventMarkers(targets) {
                #if DEBUG
                eventMarkerRefreshCount += 1
                eventMarkerRefreshMilliseconds += (ProcessInfo.processInfo.systemUptime - refreshStarted) * 1000
                #endif
                overlay.needsDisplay = true
            } else if let scroll = descendants(host.view).compactMap({ $0 as? NSScrollView }).first,
                      let image = CalendarSnapshotImage.capture(scroll, in: scroll.bounds) {
                overlay.refreshEventContent(image)
            }
        }.store(in: &subscriptions)
        model.$calendarScrollRevision.dropFirst().sink { [weak self] _ in
            guard let self, transitioningCalendarLayout else { return }
            finishTransition()
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = CalendarPresentationView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.setAccessibilityElement(false)
        view.addSubview(material)
        view.addSubview(host.view)
        updateMaterial()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let hostFrame = NSRect(origin: .zero, size: targetSize)
        if host.view.frame != hostFrame { host.view.frame = hostFrame }
        overlay?.frame = view.bounds
        material.frame = view.bounds
    }

    func cancelTransition() {
        serial += 1
        preparation?.cancel()
        preparation = nil
        displayLink?.invalidate()
        displayLink = nil
        #if DEBUG
        if let overlay { drawingMilliseconds = overlay.drawingMilliseconds }
        #endif
        overlay?.removeFromSuperview()
        overlay = nil
        transitioningCalendarLayout = false
        transitioningShell?.endTransition()
        transitioningShell = nil
        progress = 1
        elapsedFraction = 1
    }

    private func updateMaterial() {
        material.isHidden = !(defaults.object(forKey: "blurEnabled") as? Bool ?? true)
        (view as? CalendarPresentationView)?.drawsSolidBackground = material.isHidden
        view.needsDisplay = true
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private enum Transition {
        case year(Bool)
        case settings(Bool)
        case events(CalendarEventDisplay)
        case agenda(CalendarAgendaSelection?)

        var changesCalendarLayout: Bool {
            switch self {
            case .events, .agenda: return true
            default: return false
            }
        }

        var zoomsDates: Bool {
            if case .year = self { return true }
            return false
        }

        var changesAgenda: Bool {
            if case .agenda = self { return true }
            return false
        }

        @MainActor func matches(_ model: CalendarModel) -> Bool {
            switch self {
            case .year(let year): return model.showingYearOverview == year && !model.showingSettings
            case .settings(let settings): return model.showingSettings == settings
            case .events(let mode): return model.events.mode == mode && !model.showingSettings && !model.showingYearOverview
            case .agenda(let value): return model.agenda == value && !model.showingSettings && !model.showingYearOverview
            }
        }
    }

    private func prepare(_ transition: Transition) {
        guard view.window?.isVisible == true else { cancelTransition(); return }
        if transition.zoomsDates, model.showingSettings { return }
        let modeOverflow = transition.changesCalendarLayout && (transition.changesAgenda || model.agenda != nil)
            ? CalendarDayAgendaLayout.maximumHeight : 0
        transitioningCalendarLayout = transition.changesCalendarLayout
        #if DEBUG
        if transition.changesCalendarLayout { eventPreparationCount += 1 }
        #endif
        // 准备新终点时继续展示旧运动；只有关闭才立即释放全部动画状态。
        serial += 1
        preparation?.cancel()
        preparation = nil
        #if DEBUG
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        preparationPhases = [:]
        handoffDateError = nil
        model.timelineBuildMilliseconds = 0
        displayTimestamps = []
        frameMilliseconds = []
        drawingMilliseconds = []
        #endif
        let parts = model.engine.calendar.dateComponents([.year, .month], from: model.overviewFocusMonth ?? model.month)
        let month = parts.year! * 100 + parts.month!
        guard let shell = descendants(host.view).compactMap({ $0 as? CalendarShellView }).first else { cancelTransition(); return }
        if transition.zoomsDates, let overlay, overlay.needsModeCanvas {
            let opacity = shell.content.alphaValue
            shell.content.alphaValue = 1
            let detail = CalendarZoomSnapshot.capture(host.view, month: month)
            shell.content.alphaValue = opacity
            if let detail { overlay.prepareModeCanvas(detail) }
        }
        if overlay == nil {
            guard let source = CalendarZoomSnapshot.capture(host.view, month: month,
                capturesModeElements: transition.changesCalendarLayout, modeOverflow: modeOverflow) else { cancelTransition(); return }
            let layer = CalendarZoomOverlay(source: source)
            layer.frame = view.bounds
            layer.appearance = host.view.effectiveAppearance
            view.addSubview(layer)
            overlay = layer
            progress = 0
            elapsedFraction = 0
            transitioningShell = shell
            shell.transitionCard = source.card
            shell.transitionHeight = source.size.height
            shell.content.alphaValue = 0
        }
        shell.prepareTransition(preservesChrome: transition.changesCalendarLayout)
        #if DEBUG
        preparationPhases["sourceMS"] = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1000
        #endif
        let request = serial
        preparation = Task { [weak self] in
            await Task.yield()
            guard let self, serial == request, !Task.isCancelled else { return }
            defer {
                if serial == request {
                    preparation = nil
                    #if DEBUG
                    if displayLink == nil && !controlsAnimationClock { finishTransition() }
                    #else
                    if displayLink == nil { finishTransition() }
                    #endif
                }
            }
            guard transition.matches(model), view.window?.isVisible == true else { return }
            // Published 在赋值前通知；快照可能消费旧页面刷新，赋值后重新通知。
            model.objectWillChange.send()
            await Task.yield()
            guard serial == request, !Task.isCancelled, let layer = overlay else { return }
            #if DEBUG
            let layoutStarted = ProcessInfo.processInfo.systemUptime
            preparationPhases["handoffMS"] = (layoutStarted - preparationStarted) * 1000 - (preparationPhases["sourceMS"] ?? 0)
            #endif
            targetSize = host.view.fittingSize
            host.view.frame = NSRect(origin: .zero, size: targetSize)
            host.view.layoutSubtreeIfNeeded()
            shell.content.alphaValue = 1
            #if DEBUG
            let captureStarted = ProcessInfo.processInfo.systemUptime
            preparationPhases["layoutMS"] = (captureStarted - layoutStarted) * 1000
            #endif
            let destination = CalendarZoomSnapshot.capture(host.view, month: month,
                capturesModeElements: transition.changesCalendarLayout, modeOverflow: modeOverflow)
            shell.content.alphaValue = 0
            guard let destination else { cancelTransition(); return }
            #if DEBUG
            preparationPhases["destinationMS"] = (ProcessInfo.processInfo.systemUptime - captureStarted) * 1000
            preparationPhases["timelineBuildMS"] = model.timelineBuildMilliseconds
            let oldCard = layer.cardFrame.animatableData
            let oldVelocity = layer.cardVelocity.animatableData
            let oldCanvas = layer.canvasMotion
            let oldMode = layer.modeMotion
            let wasMoving = layer.destination != nil
            #endif
            var reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            #if DEBUG
            reduced = reduceMotionOverride ?? reduced
            #endif
            guard layer.retarget(destination, duration: transition.zoomsDates ? 0.3 : 0.22,
                                 reduceMotion: reduced, zoomsDates: transition.zoomsDates,
                                 changesCalendarLayout: transition.changesCalendarLayout) else {
                cancelTransition()
                return
            }
            #if DEBUG
            if wasMoving, !layer.reducedMotion {
                retargetPositionError = (layer.cardFrame.animatableData - oldCard).magnitudeSquared.squareRoot()
                retargetVelocityError = (layer.cardVelocity.animatableData - oldVelocity).magnitudeSquared.squareRoot()
                if let old = oldCanvas, let new = layer.canvasMotion {
                    retargetPositionError = max(retargetPositionError, (old.0 - new.0).magnitudeSquared.squareRoot())
                    retargetVelocityError = max(retargetVelocityError, (old.1 - new.1).magnitudeSquared.squareRoot())
                }
                if let oldMode, let newMode = layer.modeMotion {
                    for (id, old) in oldMode {
                        guard let new = newMode[id] else { continue }
                        retargetPositionError = max(retargetPositionError, (old.0.animatableData - new.0.animatableData).magnitudeSquared.squareRoot())
                        retargetVelocityError = max(retargetVelocityError, (old.1 - new.1).magnitudeSquared.squareRoot())
                    }
                }
                retargetCount += 1
            }
            preparationMilliseconds = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1000
            #endif
            shell.beginAnimation()
            lastFrameTime = CACurrentMediaTime()
            applyFrame(deltaTime: 0)
            #if DEBUG
            if controlsAnimationClock {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            #endif
            if displayLink == nil {
                let target = CalendarDisplayLinkTarget { [weak self] link in
                    guard let self else { link.invalidate(); return }
                    #if DEBUG
                    driverCallbackCount += 1
                    #endif
                    advance(link)
                }
                let link = view.displayLink(target: target, selector: #selector(CalendarDisplayLinkTarget.tick(_:)))
                CalendarRefreshPolicy.apply(to: link, in: view,
                    enabled: defaults.bool(forKey: CalendarRefreshPolicy.preferenceKey))
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        }
    }

    private func advance(_ link: CADisplayLink) {
        guard displayLink === link else { return }
        guard view.window?.isVisible == true else { finishTransition(); return }
        CalendarRefreshPolicy.apply(to: link, in: view,
            enabled: defaults.bool(forKey: CalendarRefreshPolicy.preferenceKey))
        #if DEBUG
        let frameStarted = ProcessInfo.processInfo.systemUptime
        displayTimestamps.append(link.targetTimestamp)
        defer { frameMilliseconds.append((ProcessInfo.processInfo.systemUptime - frameStarted) * 1000) }
        #endif
        let next = max(lastFrameTime, link.targetTimestamp)
        applyFrame(deltaTime: next - lastFrameTime)
        lastFrameTime = next
        if preparation == nil, overlay?.isSettled == true { finishTransition() }
    }

    private func applyFrame(deltaTime: Double) {
        guard let overlay, overlay.destination != nil, let shell = transitioningShell else { return }
        overlay.advance(deltaTime: deltaTime)
        elapsedFraction = min(1, overlay.elapsed / overlay.duration)
        progress = overlay.progress
        shell.updateTransition(card: overlay.cardFrame, height: overlay.height)
        if preparation == nil || deltaTime == 0 { shell.updateChrome(fraction: overlay.contentFraction) }
        let size = NSSize(width: 320, height: overlay.height)
        if preferredContentSize != size { preferredContentSize = size }
        overlay.needsDisplay = true
    }

    private func finishTransition() {
        #if DEBUG
        handoffDateError = overlay?.detailHandoffError
        #endif
        cancelTransition()
        // 释放终点布局缓存后重新测量，接纳动画期间可能更新的日期详情。
        host.view.layoutSubtreeIfNeeded()
        targetSize = host.view.fittingSize
        preferredContentSize = targetSize
    }
}

private final class CalendarPresentationView: NSView {
    var drawsSolidBackground = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard drawsSolidBackground else { return }
        CalendarSurface.settingsColor.setFill()
        bounds.fill()
    }
}

// 系统 Spring 持有每个值的当前速度；重定向只换终点，不重置运动状态。
private struct CalendarSpringValue<Value: Animatable> {
    var value: Value
    var target: Value
    var velocity: Value.AnimatableData = .zero

    init(_ value: Value) { self.value = value; target = value }

    mutating func advance(_ spring: Spring, by deltaTime: Double) {
        var data = value.animatableData
        spring.update(value: &data, velocity: &velocity, target: target.animatableData, deltaTime: deltaTime)
        value.animatableData = data
    }

    var isSettled: Bool {
        (value.animatableData - target.animatableData).magnitudeSquared < 0.01
            && velocity.magnitudeSquared < 1
    }
}

// 相机带动整张画布；焦点日期网格使用同一缩放进度展开。
@MainActor
private final class CalendarZoomCanvas {
    let overview: CalendarZoomSnapshot
    let detail: CalendarZoomSnapshot
    let detailTransform: CGRect
    var camera: CalendarSpringValue<CGRect>
    let matchedDayCount: Int
    private let rowsExpansion: CGFloat
    private let gridCenter: CGPoint
    private struct DatePair {
        let start: CalendarZoomAnchor?
        let end: CalendarZoomAnchor?
    }
    private let dates: [DatePair]
    private let overviewBody: NSImage
    private let detailBody: NSImage
    private let captions: [CalendarZoomCaption]

    init?(overview: CalendarZoomSnapshot, detail: CalendarZoomSnapshot, startsInOverview: Bool) {
        guard overview.month == detail.month, overview.canvasContent != nil, detail.canvasContent != nil else { return nil }
        let days = Dictionary(overview.anchors.map { ($0.day, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let pairs = detail.anchors.compactMap { anchor -> (NSRect, NSRect)? in
            days[anchor.day].map { ($0, anchor.frame) }
        }
        guard pairs.count >= 2 else { return nil }
        let count = CGFloat(pairs.count)
        let yearCenter = NSPoint(x: pairs.reduce(0) { $0 + $1.0.midX } / count,
                                 y: pairs.reduce(0) { $0 + $1.0.midY } / count)
        let monthCenter = NSPoint(x: pairs.reduce(0) { $0 + $1.1.midX } / count,
                                  y: pairs.reduce(0) { $0 + $1.1.midY } / count)
        let variance = pairs.reduce(CGFloat(0)) { $0 + pow($1.0.midX - yearCenter.x, 2) }
        guard variance > 1 else { return nil }
        let scale = pairs.reduce(CGFloat(0)) { $0 + ($1.0.midX - yearCenter.x) * ($1.1.midX - monthCenter.x) } / variance
        guard scale.isFinite, scale > 1 else { return nil }
        self.overview = overview
        self.detail = detail
        matchedDayCount = pairs.count
        detailTransform = CGRect(x: monthCenter.x - scale * yearCenter.x,
                                 y: monthCenter.y - scale * yearCenter.y, width: scale, height: scale)
        camera = CalendarSpringValue(startsInOverview ? Self.identity : detailTransform)
        gridCenter = yearCenter
        let yVariance = pairs.reduce(CGFloat(0)) { $0 + pow($1.0.midY - yearCenter.y, 2) }
        let yCovariance = pairs.reduce(CGFloat(0)) { $0 + ($1.0.midY - yearCenter.y) * ($1.1.midY - monthCenter.y) }
        rowsExpansion = yVariance > 1 ? yCovariance / yVariance / scale : 1
        guard rowsExpansion.isFinite, rowsExpansion > 0 else { return nil }
        let startDays = Dictionary(overview.anchors.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let endDays = Dictionary(detail.anchors.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        dates = Set(startDays.keys).union(endDays.keys).sorted().map { DatePair(start: startDays[$0], end: endDays[$0]) }
        // 背景按最大显示尺寸预绘制一次，逐帧只合成；日期仍按当前字号原生绘制。
        let resolution = max(overview.backingScale, detail.backingScale)
        overviewBody = CalendarSnapshotImage.rasterized(overview.canvasContent!, scale: resolution * scale) ?? overview.canvasContent!
        detailBody = CalendarSnapshotImage.rasterized(detail.canvasContent!, scale: resolution) ?? detail.canvasContent!
        captions = overview.captions.map { caption in
            CalendarZoomCaption(image: CalendarSnapshotImage.rasterized(caption.image, scale: resolution * scale) ?? caption.image,
                                frame: caption.frame)
        }
    }

    static let identity = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var layoutFraction: CGFloat {
        layoutFraction(for: camera.value)
    }
    private func layoutFraction(for transform: CGRect) -> CGFloat {
        min(1, max(0, (transform.width - 1) / (detailTransform.width - 1)))
    }
    var isSettled: Bool {
        // 相机参数的误差会被日期坐标放大，交接还需检查屏幕上的实际日期框。
        camera.isSettled && dates.allSatisfy {
            (dateFrame($0).animatableData - dateFrame($0, through: camera.target).animatableData).magnitudeSquared < 0.01
        }
    }
    var detailFraction: CGFloat { smoothstep((layoutFraction - 0.25) / 0.75) }
    func target(overview: Bool) { camera.target = overview ? Self.identity : detailTransform }

    func project(_ rect: CGRect) -> CGRect { Self.project(rect, through: camera.value) }
    static func project(_ rect: CGRect, through transform: CGRect) -> CGRect {
        CGRect(x: rect.minX * transform.width + transform.minX,
               y: rect.minY * transform.width + transform.minY,
               width: rect.width * transform.width, height: rect.height * transform.width)
    }
    private func monthWorldRect(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - detailTransform.minX) / detailTransform.width,
               y: (rect.minY - detailTransform.minY) / detailTransform.width,
               width: rect.width / detailTransform.width, height: rect.height / detailTransform.width)
    }
    private var detailWorldRect: CGRect {
        let rect = monthWorldRect(detail.card)
        let rowScale = (1 - layoutFraction) / rowsExpansion + layoutFraction
        return CGRect(x: rect.minX, y: gridCenter.y + (rect.minY - gridCenter.y) * rowScale,
                      width: rect.width, height: rect.height * rowScale)
    }
    private func dateFrame(_ pair: DatePair, through transform: CGRect? = nil) -> CGRect {
        let transform = transform ?? camera.value
        let fraction = layoutFraction(for: transform)
        let end = pair.end.map { monthWorldRect($0.frame) }
        let start = pair.start?.frame
        var first = start ?? end!, last = end ?? start!
        // 被视口截掉的周也沿同一个网格展开，不能在旧位置淡化出第二套日期。
        if start == nil {
            first.origin.y = gridCenter.y + (first.midY - gridCenter.y) / rowsExpansion - first.height / 2
        }
        if end == nil {
            last.origin.y = gridCenter.y + (last.midY - gridCenter.y) * rowsExpansion - last.height / 2
        }
        var rect = first
        var delta = last.animatableData - first.animatableData
        delta.scale(by: fraction)
        rect.animatableData += delta
        return Self.project(rect, through: transform)
    }
    func draw(alpha: CGFloat) {
        let overviewRect = project(overview.card)
        #if DEBUG
        renderedOverviewRect = overviewRect
        renderedDateCounts = [:]
        renderedFrames = [:]
        #endif
        if detailFraction < 1 {
            overviewBody.draw(in: overviewRect, from: .zero, operation: .sourceOver,
                              fraction: alpha * (1 - detailFraction), respectFlipped: true, hints: nil)
        }
        if detailFraction > 0 {
            detailBody.draw(in: project(detailWorldRect), from: .zero, operation: .sourceOver,
                            fraction: alpha * detailFraction, respectFlipped: true, hints: nil)
        }
        let captionOpacity = 1 - smoothstep(layoutFraction / 0.55)
        if captionOpacity > 0 {
            for caption in captions {
                caption.image.draw(in: project(caption.frame), from: .zero, operation: .sourceOver,
                                   fraction: alpha * captionOpacity, respectFlipped: true, hints: nil)
            }
        }
        for pair in dates {
            let anchor = pair.end ?? pair.start!
            let opacity = alpha * (pair.start == nil ? layoutFraction : pair.end == nil ? 1 - layoutFraction : 1)
            guard opacity > 0 else { continue }
            let rect = dateFrame(pair)
            let startSize = pair.start?.fontSize ?? pair.end!.fontSize / detailTransform.width
            let endSize = pair.end.map { $0.fontSize / detailTransform.width } ?? startSize
            let size = (startSize + (endSize - startSize) * layoutFraction) * camera.value.width
            let startWeight = pair.start?.weight ?? anchor.weight
            let weight = startWeight + (anchor.weight - startWeight) * layoutFraction
            let color = (pair.start?.color ?? anchor.color).blended(withFraction: layoutFraction, of: anchor.color) ?? anchor.color
            if anchor.circle {
                NSColor(srgbRed: 0.89, green: 0.20, blue: 0.15, alpha: opacity).setFill()
                let diameter = min(rect.width, rect.height)
                NSBezierPath(ovalIn: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                           width: diameter, height: diameter)).fill()
            }
            let text = NSAttributedString(string: String(anchor.day), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: NSFont.Weight(rawValue: weight)),
                .foregroundColor: color.withAlphaComponent(color.alphaComponent * opacity)
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            #if DEBUG
            renderedDateCounts[anchor.day, default: 0] += 1
            renderedFrames[anchor.day] = rect
            #endif
        }
    }
    var movingDayFrame: CGRect? { dates.first.map { dateFrame($0) } }

    #if DEBUG
    var detailHandoffError: CGFloat? {
        guard camera.target == detailTransform else { return nil }
        return dates.reduce(CGFloat(0)) { error, pair in
            guard let end = pair.end else { return error }
            let frame = dateFrame(pair)
            return max(error, hypot(frame.midX - end.frame.midX, frame.midY - end.frame.midY))
        }
    }
    private var renderedOverviewRect: CGRect?
    private var renderedDateCounts: [Int: Int] = [:]
    private var renderedFrames: [Int: CGRect] = [:]
    var sample: [String: Double]? {
        guard let rendered = renderedOverviewRect, let focus = overview.overviewMonths[overview.month],
              let neighbor = overview.overviewMonths.sorted(by: { $0.key < $1.key }).first(where: {
                  $0.key != overview.month && overview.card.intersects($0.value)
              })?.value else { return nil }
        // 从实际提交给绘制的整张画布矩形还原邻月位置，覆盖绘制漏用相机的回归。
        let scale = rendered.width / overview.card.width
        let transform = CGRect(x: rendered.minX - overview.card.minX * scale,
                               y: rendered.minY - overview.card.minY * scale, width: scale, height: scale)
        let first = Self.project(focus, through: transform), second = Self.project(neighbor, through: transform)
        return ["scale": scale, "detail": detailFraction,
                "focusMonth": Double(overview.month),
                "vector": overview.canvasContent?.representations.contains { $0 is NSPDFImageRep } == true ? 1 : 0,
                "dateCopies": Double(renderedDateCounts.values.max() ?? 0),
                "backgroundCirclePixels": Double(overview.suppressedCircleInk + detail.suppressedCircleInk),
                "dateCount": Double(renderedDateCounts.count),
                "expectedDateCount": Double(layoutFraction == 0 ? overview.anchors.count
                    : layoutFraction == 1 ? detail.anchors.count : dates.count),
                "layout": layoutFraction,
                "endError": renderedFrames.reduce(0) { error, item in
                    guard let end = detail.anchors.first(where: { $0.day == item.key }) else { return error }
                    return max(error, hypot(item.value.midX - end.frame.midX, item.value.midY - end.frame.midY))
                },
                "focusX": first.midX, "focusY": first.midY, "focusWidth": first.width, "focusHeight": first.height,
                "neighborX": second.midX, "neighborY": second.midY, "neighborWidth": second.width,
                "neighborHeight": second.height,
                "baseFocusX": focus.midX, "baseFocusY": focus.midY, "baseFocusWidth": focus.width,
                "baseFocusHeight": focus.height, "baseNeighborX": neighbor.midX, "baseNeighborY": neighbor.midY,
                "baseNeighborWidth": neighbor.width, "baseNeighborHeight": neighbor.height]
    }
    #endif
}

private func smoothstep(_ value: CGFloat) -> CGFloat {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
}

@MainActor
private final class CalendarModeGrid {
    private struct Marker {
        var descriptor: CalendarEventMarker
        var motion: CalendarSpringValue<CalendarEventMarkerStyle>
    }
    @MainActor private struct Cell {
        var markers: [CalendarEventMarker.ID: Marker] = [:]
        var frame: CalendarSpringValue<CGRect>
        var source: CalendarModeImage?
        var destination: CalendarModeImage?
        var sourceOpacity: CGFloat
        var destinationOpacity: CGFloat

        func draw(fraction: CGFloat, scale: CGFloat) {
            let rect = frame.value
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            defer { context.restoreGState() }
            context.clip(to: rect)
            if source == nil && destination == nil {
                let opacity = sourceOpacity * (1 - fraction) + destinationOpacity * fraction
                NSColor.labelColor.withAlphaComponent(0.10 * opacity).setFill()
                rect.fill()
                return
            }
            // 日期和农历使用相同的局部坐标；只移动格子，不拉伸文字。
            // 隔离层中的预乘透明度相加，避免同位置文字交叉淡化时发灰。
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            source?.draw(at: rect.origin, scale: scale, operation: .sourceOver, fraction: 1 - fraction)
            destination?.draw(at: rect.origin, scale: scale, operation: .plusLighter, fraction: fraction)
            context.endTransparencyLayer()
        }

        mutating func retargetMarkers(_ destination: [CalendarEventMarker]) {
            let next = Dictionary(destination.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Array(markers.keys) {
                if let descriptor = next[id] {
                    // 收起时保留原胶囊标题，避免“+N项”在淡出前跳成事件名。
                    if descriptor.style.detailOpacity > 0 || markers[id]!.motion.value.detailOpacity < 0.000001 {
                        markers[id]!.descriptor = descriptor
                    }
                    markers[id]!.motion.target = descriptor.style
                } else {
                    // 隐藏会立即清空事件库；仅保留离场外观，直到透明度收敛。
                    markers[id]!.motion.target = markers[id]!.motion.value.collapsed
                }
            }
            for descriptor in destination where markers[descriptor.id] == nil {
                var motion = CalendarSpringValue(descriptor.style.collapsed)
                motion.target = descriptor.style
                markers[descriptor.id] = Marker(descriptor: descriptor, motion: motion)
            }
        }

        func drawMarkers(dark: Bool) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: frame.value.minX, y: frame.value.minY)
            // 标记可以随行高收拢，但不能越过相邻日期列。
            let height = max(frame.value.height, markers.values.map { $0.motion.value.frame.maxY }.max() ?? 0)
            context.clip(to: CGRect(x: 0, y: 0, width: frame.value.width, height: height))
            for marker in markers.values {
                CalendarEventDrawing.draw(marker: marker.descriptor, style: marker.motion.value, dark: dark)
            }
        }

        func compositedImage(fraction: CGFloat, scale: CGFloat) -> CalendarModeImage? {
            guard source != nil || destination != nil else { return nil }
            let rect = frame.value
            if fraction == 0, let source { return source }
            let area = CGRect(x: floor(rect.minX * scale) / scale, y: floor(rect.minY * scale) / scale,
                              width: ceil(rect.maxX * scale) / scale - floor(rect.minX * scale) / scale,
                              height: ceil(rect.maxY * scale) / scale - floor(rect.minY * scale) / scale)
            let image = NSImage(size: area.size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.saveGState()
                defer { context.restoreGState() }
                context.translateBy(x: -area.minX, y: -area.minY)
                draw(fraction: fraction, scale: scale)
                return true
            }
            guard let raster = CalendarSnapshotImage.rasterized(image, scale: scale) else { return nil }
            return CalendarModeImage(image: raster,
                offset: CGPoint(x: area.minX - rect.minX, y: area.minY - rect.minY))
        }
    }

    private var cells: [Int: Cell] = [:]
    private var scale: CGFloat
    #if DEBUG
    private var targetCount = 0
    #endif

    init(source: CalendarZoomSnapshot) {
        scale = source.backingScale
        for element in source.modeElements ?? [] {
            var cell = Cell(frame: CalendarSpringValue(element.frame), source: element.image,
                            destination: element.image, sourceOpacity: 1, destinationOpacity: 1)
            for marker in element.markers {
                cell.markers[marker.id] = Marker(descriptor: marker, motion: CalendarSpringValue(marker.style))
            }
            cells[element.id] = cell
        }
    }

    func retarget(_ destination: CalendarZoomSnapshot, from card: CGRect, fraction: CGFloat) -> Bool {
        let next = Dictionary((destination.modeElements ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        #if DEBUG
        // 月份标题允许在视口边界露出一小部分；完整性采样只计七列日期和分隔线。
        targetCount = next.values.filter { $0.id % 8 < 7 || $0.image == nil }.count
        #endif
        for id in Set(cells.keys).union(next.keys) {
            if var cell = cells[id] {
                let opacity = cell.sourceOpacity * (1 - fraction) + cell.destinationOpacity * fraction
                let image = cell.compositedImage(fraction: fraction, scale: scale)
                guard image != nil || (cell.source == nil && cell.destination == nil) else { return false }
                cell.source = image
                cell.sourceOpacity = opacity
                cell.destination = next[id]?.image
                cell.destinationOpacity = next[id] == nil ? 0 : 1
                cell.frame.target = next[id]?.frame ?? Self.project(cell.frame.value, from: card, to: destination.card)
                cell.retargetMarkers(next[id]?.markers ?? [])
                cells[id] = cell
            } else if let element = next[id] {
                var frame = CalendarSpringValue(Self.project(element.frame, from: destination.card, to: card))
                frame.target = element.frame
                var cell = Cell(frame: frame, source: nil, destination: element.image, sourceOpacity: 0, destinationOpacity: 1)
                cell.retargetMarkers(element.markers)
                cells[id] = cell
            }
        }
        scale = destination.backingScale
        return true
    }

    func refreshMarkers(_ targets: [Int: [CalendarEventMarker]]) {
        for id in Array(cells.keys) where id % 8 < 7 {
            cells[id]!.retargetMarkers(targets[id] ?? [])
        }
    }

    private static func project(_ rect: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: destination.minY + (rect.minY - source.minY) * destination.height / source.height,
               width: rect.width, height: rect.height)
    }

    func advance(_ spring: Spring, deltaTime: Double) {
        for id in Array(cells.keys) {
            cells[id]!.frame.advance(spring, by: deltaTime)
            for key in Array(cells[id]!.markers.keys) {
                cells[id]!.markers[key]!.motion.advance(spring, by: deltaTime)
            }
        }
    }
    var isSettled: Bool {
        cells.values.allSatisfy { $0.frame.isSettled && $0.markers.values.allSatisfy { $0.motion.isSettled } }
    }

    func draw(fraction: CGFloat, dark: Bool) {
        #if DEBUG
        renderedMarkers = [:]
        renderedFrames = [:]
        renderedCells = [:]
        #endif
        for id in cells.keys.sorted() {
            cells[id]!.draw(fraction: fraction, scale: scale)
            cells[id]!.drawMarkers(dark: dark)
            #if DEBUG
            for (key, marker) in cells[id]!.markers {
                let value = marker.motion.value
                let target = marker.motion.target
                var velocity = value
                velocity.animatableData = marker.motion.velocity
                renderedMarkers["\(id):\(key.event):\(key.start.timeIntervalSinceReferenceDate)"] = [
                    "x": value.frame.minX, "y": value.frame.minY,
                    "worldX": cells[id]!.frame.value.minX + value.frame.minX,
                    "worldY": cells[id]!.frame.value.minY + value.frame.minY,
                    "width": value.frame.width, "height": value.frame.height,
                    "opacity": value.opacity, "detail": value.detailOpacity, "fill": value.fillOpacity,
                    "velocityX": velocity.frame.minX, "velocityY": velocity.frame.minY,
                    "velocityWidth": velocity.frame.width, "velocityHeight": velocity.frame.height,
                    "velocityOpacity": velocity.opacity, "velocityDetail": velocity.detailOpacity,
                    "velocityFill": velocity.fillOpacity,
                    "targetWidth": target.frame.width, "targetHeight": target.frame.height,
                    "targetOpacity": target.opacity,
                    "summary": marker.descriptor.title.hasPrefix("+") ? 1 : 0,
                    "error": (value.animatableData - target.animatableData).magnitudeSquared.squareRoot()]
            }
            renderedFrames[id] = cells[id]!.frame.value
            renderedCells[id] = ["y": cells[id]!.frame.value.minY,
                "targetY": cells[id]!.frame.target.minY,
                "opacity": (cells[id]!.source == nil ? 0 : 1 - fraction)
                    + (cells[id]!.destination == nil ? 0 : fraction)]
            #endif
        }
    }

    #if DEBUG
    private var renderedFrames: [Int: CGRect] = [:]
    private(set) var renderedCells: [Int: [String: Double]] = [:]
    private(set) var renderedMarkers: [String: [String: Double]] = [:]
    var motion: [Int: (CGRect, CGRect.AnimatableData)] {
        cells.mapValues { ($0.frame.value, $0.frame.velocity) }
    }
    var sample: [String: Double]? {
        guard let id = cells.keys.sorted().first, let first = renderedFrames[id], let cell = cells[id] else { return nil }
        let error = renderedFrames.reduce(CGFloat.zero) { error, item in
            max(error, (item.value.animatableData - cells[item.key]!.frame.target.animatableData).magnitudeSquared.squareRoot())
        }
        var velocity = CGRect.zero
        velocity.animatableData = cell.frame.velocity
        return ["elements": Double(cells.count), "rendered": Double(renderedFrames.count), "firstID": Double(id),
                "destinationElements": Double(targetCount),
                "firstY": first.minY, "firstVelocityY": velocity.minY,
                "endError": error]
    }
    #endif
}

private final class CalendarZoomOverlay: NSView {
    #if DEBUG
    var drawingMilliseconds: [Double] = []
    var canvasMotion: (CGRect.AnimatableData, CGRect.AnimatableData)? {
        canvas.map { ($0.camera.value.animatableData, $0.camera.velocity) }
    }
    var canvasSample: [String: Double]? { canvasOpacity > 0 ? canvas?.sample : nil }
    var detailHandoffError: CGFloat? { canvasOpacity > 0 ? canvas?.detailHandoffError : nil }
    var modeSample: [String: Double]? { modeGrid?.sample }
    var modeCells: [Int: [String: Double]] { modeGrid?.renderedCells ?? [:] }
    var markerSample: [String: [String: Double]]? { modeGrid?.renderedMarkers }
    var modeMotion: [Int: (CGRect, CGRect.AnimatableData)]? { modeGrid?.motion }
    #endif
    private var source: CalendarZoomSnapshot
    private(set) var destination: CalendarZoomSnapshot?
    private var canvas: CalendarZoomCanvas?
    private var modeGrid: CalendarModeGrid?
    private var modeCanvas: CalendarZoomSnapshot?
    var needsModeCanvas: Bool { modeGrid != nil || destination?.modeElements != nil || source.modeElements != nil }
    func prepareModeCanvas(_ snapshot: CalendarZoomSnapshot) { modeCanvas = snapshot }
    func refreshEventMarkers(_ targets: [Int: [CalendarEventMarker]]) -> Bool {
        guard let modeGrid else { return false }
        modeGrid.refreshMarkers(targets)
        return true
    }
    func refreshEventContent(_ image: NSImage) {
        destination?.content = image
        needsDisplay = true
    }
    private var canvasOpacity: CGFloat = 0
    private var startCanvasOpacity: CGFloat = 0
    private var targetCanvasOpacity: CGFloat = 0
    private var card: CalendarSpringValue<CGRect>
    private var windowHeight: CalendarSpringValue<CGFloat>
    private var spring = Spring(duration: 0.3, bounce: 0)
    private(set) var duration = 0.3
    private(set) var elapsed = 0.0
    private(set) var matchedDayCount = 0
    private(set) var reducedMotion = false
    private var drawingBodyOnly = false
    override var isFlipped: Bool { true }

    var progress: CGFloat { reducedMotion ? contentFraction : spring.value(target: CGFloat(1), time: elapsed) }
    var contentFraction: CGFloat {
        destination == nil ? 0 : smoothstep(elapsed / (reducedMotion ? 0.12 : 0.18))
    }
    var height: CGFloat { windowHeight.value }
    var cardFrame: NSRect { card.value }
    var cardVelocity: NSRect {
        var rect = NSRect.zero
        rect.animatableData = card.velocity
        return rect
    }
    var movingDayFrame: NSRect? {
        if let canvas, canvasOpacity > 0, !reducedMotion { return canvas.movingDayFrame }
        return destination?.anchors.first?.frame
    }
    var isSettled: Bool {
        guard contentFraction == 1 else { return false }
        return reducedMotion || (card.isSettled && windowHeight.isSettled
            && (canvasOpacity == 0 || canvas?.isSettled != false) && modeGrid?.isSettled != false)
    }

    init(source: CalendarZoomSnapshot) {
        self.source = source
        card = CalendarSpringValue(source.card)
        windowHeight = CalendarSpringValue(source.size.height)
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { cardFrame.contains(point) ? self : nil }

    func retarget(_ destination: CalendarZoomSnapshot, duration: Double, reduceMotion: Bool, zoomsDates: Bool,
                  changesCalendarLayout: Bool) -> Bool {
        let leavingMode = needsModeCanvas
        let previous = modeCanvas ?? self.destination ?? source
        modeCanvas = nil
        let outgoingDays = Set(previous.anchors.map(\.day))
        matchedDayCount = destination.anchors.filter { outgoingDays.contains($0.day) && previous.month == destination.month }.count
        // 已有画布跨设置保留，返回时可以继续原来的位置和速度。
        let canReuse = !changesCalendarLayout && !leavingMode && canvas?.overview.month == destination.month && !destination.anchors.isEmpty
        if canReuse { matchedDayCount = canvas!.matchedDayCount }
        let candidate: CalendarZoomCanvas?
        if !canReuse, zoomsDates, previous.isOverview != destination.isOverview {
            candidate = CalendarZoomCanvas(overview: previous.isOverview ? previous : destination,
                                           detail: previous.isOverview ? destination : previous,
                                           startsInOverview: previous.isOverview)
        } else { candidate = nil }
        let nextReducedMotion = reduceMotion || (zoomsDates && !canReuse && candidate == nil)
        if self.destination != nil && !(changesCalendarLayout && !nextReducedMotion && modeGrid != nil) {
            // 通用正文只保留当前混合结果；活动画布独立保留，跨页面淡化也不冻结其速度。
            drawingBodyOnly = !nextReducedMotion && (canReuse || (canvas != nil && candidate == nil))
            let image = CalendarSnapshotImage.capture(self, in: cardFrame)
            drawingBodyOnly = false
            guard let image else { return false }
            source = CalendarZoomSnapshot(content: image, size: NSSize(width: 320, height: height),
                                          card: cardFrame, anchors: [], month: previous.month)
        }
        let nextModeGrid: CalendarModeGrid?
        if changesCalendarLayout, !nextReducedMotion, destination.modeElements != nil {
            nextModeGrid = modeGrid ?? (source.modeElements == nil ? nil : CalendarModeGrid(source: source))
            if let nextModeGrid, !nextModeGrid.retarget(destination, from: card.value, fraction: contentFraction) { return false }
        } else { nextModeGrid = nil }
        modeGrid = nextModeGrid
        reducedMotion = nextReducedMotion
        self.duration = reducedMotion ? 0.12 : duration
        spring = Spring(duration: duration, bounce: 0)
        if reducedMotion {
            canvas = nil
            canvasOpacity = 0
        } else if let candidate {
            canvas = candidate
            canvasOpacity = self.destination == nil ? 1 : 0
        }
        startCanvasOpacity = canvasOpacity
        targetCanvasOpacity = !reducedMotion && (canReuse || candidate != nil) && !destination.anchors.isEmpty ? 1 : 0
        if targetCanvasOpacity == 1 { canvas?.target(overview: destination.isOverview) }
        self.destination = destination
        card.target = destination.card
        windowHeight.target = destination.size.height
        if reducedMotion {
            card = CalendarSpringValue(destination.card)
            windowHeight = CalendarSpringValue(destination.size.height)
        }
        elapsed = 0
        return true
    }

    func advance(deltaTime: Double) {
        elapsed += deltaTime
        if !reducedMotion {
            card.advance(spring, by: deltaTime)
            windowHeight.advance(spring, by: deltaTime)
            canvas?.camera.advance(spring, by: deltaTime)
            modeGrid?.advance(spring, deltaTime: deltaTime)
        }
        canvasOpacity = startCanvasOpacity + (targetCanvasOpacity - startCanvasOpacity) * contentFraction
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        let drawingStarted = ProcessInfo.processInfo.systemUptime
        defer { drawingMilliseconds.append((ProcessInfo.processInfo.systemUptime - drawingStarted) * 1000) }
        #endif
        let destination = destination ?? source
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let path = NSBezierPath(roundedRect: cardFrame, xRadius: 12, yRadius: 12)
        path.addClip()
        if let modeGrid {
            modeGrid.draw(fraction: contentFraction,
                          dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            return
        }
        if drawingBodyOnly || canvasOpacity < 1 {
            let normalization = drawingBodyOnly ? max(0.001, 1 - canvasOpacity) : 1
            drawImage(source, alpha: (1 - contentFraction) * (1 - startCanvasOpacity) / normalization)
            drawImage(destination, alpha: contentFraction * (1 - targetCanvasOpacity) / normalization)
        }
        if !drawingBodyOnly { canvas?.draw(alpha: canvasOpacity) }
    }

    private func drawImage(_ snapshot: CalendarZoomSnapshot, alpha: CGFloat) {
        snapshot.content.draw(in: snapshot.card, from: .zero, operation: .sourceOver,
                              fraction: alpha, respectFlipped: true, hints: nil)
    }
}
