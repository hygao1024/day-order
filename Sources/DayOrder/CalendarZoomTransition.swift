import AppKit
import Combine
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
        guard rect.width > 0, rect.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }
}

private struct CalendarZoomSnapshot {
    let content: NSImage
    let size: NSSize
    let card: NSRect
    let anchors: [CalendarZoomAnchor]
    let month: Int
    var overviewMonths: [Int: NSRect] = [:]
    var canvasContent: NSImage?
    var captions: [CalendarZoomCaption] = []
    var backingScale: CGFloat = 2
    var isOverview: Bool { !overviewMonths.isEmpty }
    #if DEBUG
    var suppressedCircleInk = 0
    #endif

    @MainActor static func capture(_ root: NSView, month: Int) -> Self? {
        let views = descendants(root)
        guard let scroll = views.compactMap({ $0 as? NSScrollView }).first else { return nil }
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
        guard let content = CalendarSnapshotImage.capture(scroll, in: scroll.bounds) else { return nil }
        let captions = participants.compactMap { $0.0.zoomCaption(month: month, in: root) }
        participants.forEach { view, anchors in view.zoomHiddenDays = Set(anchors.map(\.day)); view.needsDisplay = true }
        defer { participants.forEach { view, _ in view.zoomHiddenDays = []; view.needsDisplay = true } }
        // 画布快照不包含焦点日期；正常显示和短淡化仍使用完整正文。
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

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor
final class CalendarHostingController: NSHostingController<AnyView> {
    var contentSizeChanged: ((NSSize) -> Void)?
    private var lastSize = NSSize.zero

    override func viewDidLayout() {
        super.viewDidLayout()
        // 嵌入容器后，SwiftUI 的内容高度需在布局完成时转交给弹窗。
        let size = view.fittingSize
        guard size != lastSize else { return }
        lastSize = size
        contentSizeChanged?(size)
    }
}

// 展示层拥有短暂的快照、尺寸插值与取消；不写日期选择或滚动位置。
@MainActor
final class CalendarPresentationController: NSViewController {
    let host: CalendarHostingController
    private let model: CalendarModel
    private let defaults: UserDefaults
    private var subscriptions: Set<AnyCancellable> = []
    private var preparation: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private var lastFrameTime = 0.0
    private var serial = 0
    private var overlay: CalendarZoomOverlay?
    let material = NSVisualEffectView()
    private weak var transitioningShell: CalendarShellView?
    private var targetSize = NSSize(width: 320, height: 430)
    private(set) var progress: CGFloat = 1
    private(set) var elapsedFraction: CGFloat = 1
    var isTransitioning: Bool { overlay != nil }
    var transitionView: NSView? { overlay }
    #if DEBUG
    var reduceMotionOverride: Bool?
    var hasActiveFrameDriver: Bool { displayLink != nil }
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

        var zoomsDates: Bool {
            if case .year = self { return true }
            return false
        }

        @MainActor func matches(_ model: CalendarModel) -> Bool {
            switch self {
            case .year(let year): return model.showingYearOverview == year && !model.showingSettings
            case .settings(let settings): return model.showingSettings == settings
            }
        }
    }

    private func prepare(_ transition: Transition) {
        guard view.window?.isVisible == true else { cancelTransition(); return }
        if transition.zoomsDates, model.showingSettings { return }
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
        guard let shell = descendants(host.view).compactMap({ $0 as? CalendarShellView }).first else { return }
        if overlay == nil {
            guard let source = CalendarZoomSnapshot.capture(host.view, month: month) else { return }
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
        shell.prepareTransition()
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
                    if displayLink == nil { finishTransition() }
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
            let destination = CalendarZoomSnapshot.capture(host.view, month: month)
            shell.content.alphaValue = 0
            guard let destination else { cancelTransition(); return }
            #if DEBUG
            preparationPhases["destinationMS"] = (ProcessInfo.processInfo.systemUptime - captureStarted) * 1000
            preparationPhases["timelineBuildMS"] = model.timelineBuildMilliseconds
            let oldCard = layer.cardFrame.animatableData
            let oldVelocity = layer.cardVelocity.animatableData
            let oldCanvas = layer.canvasMotion
            let wasMoving = layer.destination != nil
            #endif
            var reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            #if DEBUG
            reduced = reduceMotionOverride ?? reduced
            #endif
            guard layer.retarget(destination, duration: transition.zoomsDates ? 0.4 : 0.35,
                                 reduceMotion: reduced, zoomsDates: transition.zoomsDates) else {
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
                retargetCount += 1
            }
            preparationMilliseconds = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1000
            #endif
            shell.beginAnimation()
            lastFrameTime = CACurrentMediaTime()
            applyFrame(deltaTime: 0)
            if displayLink == nil {
                let target = CalendarDisplayLinkTarget { [weak self] link in
                    guard let self else { link.invalidate(); return }
                    #if DEBUG
                    driverCallbackCount += 1
                    #endif
                    advance(link)
                }
                let link = view.displayLink(target: target, selector: #selector(CalendarDisplayLinkTarget.tick(_:)))
                displayLink = link
                link.add(to: .main, forMode: .common)
            }
        }
    }

    private func advance(_ link: CADisplayLink) {
        guard displayLink === link else { return }
        guard view.window?.isVisible == true else { finishTransition(); return }
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

@MainActor
private final class CalendarDisplayLinkTarget: NSObject {
    let frame: (CADisplayLink) -> Void
    init(frame: @escaping (CADisplayLink) -> Void) { self.frame = frame }
    @objc func tick(_ link: CADisplayLink) { frame(link) }
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

private final class CalendarZoomOverlay: NSView {
    #if DEBUG
    var drawingMilliseconds: [Double] = []
    var canvasMotion: (CGRect.AnimatableData, CGRect.AnimatableData)? {
        canvas.map { ($0.camera.value.animatableData, $0.camera.velocity) }
    }
    var canvasSample: [String: Double]? { canvasOpacity > 0 ? canvas?.sample : nil }
    var detailHandoffError: CGFloat? { canvasOpacity > 0 ? canvas?.detailHandoffError : nil }
    #endif
    private var source: CalendarZoomSnapshot
    private(set) var destination: CalendarZoomSnapshot?
    private var canvas: CalendarZoomCanvas?
    private var canvasOpacity: CGFloat = 0
    private var startCanvasOpacity: CGFloat = 0
    private var targetCanvasOpacity: CGFloat = 0
    private var card: CalendarSpringValue<CGRect>
    private var windowHeight: CalendarSpringValue<CGFloat>
    private var spring = Spring(duration: 0.4, bounce: 0)
    private(set) var duration = 0.4
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
            && (canvasOpacity == 0 || canvas?.isSettled != false))
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

    func retarget(_ destination: CalendarZoomSnapshot, duration: Double, reduceMotion: Bool, zoomsDates: Bool) -> Bool {
        let previous = self.destination ?? source
        let outgoingDays = Set(previous.anchors.map(\.day))
        matchedDayCount = destination.anchors.filter { outgoingDays.contains($0.day) && previous.month == destination.month }.count
        // 已有画布跨设置保留，返回时可以继续原来的位置和速度。
        let canReuse = canvas?.overview.month == destination.month && !destination.anchors.isEmpty
        if canReuse { matchedDayCount = canvas!.matchedDayCount }
        let candidate: CalendarZoomCanvas?
        if !canReuse, zoomsDates, previous.isOverview != destination.isOverview {
            candidate = CalendarZoomCanvas(overview: previous.isOverview ? previous : destination,
                                           detail: previous.isOverview ? destination : previous,
                                           startsInOverview: previous.isOverview)
        } else { candidate = nil }
        let nextReducedMotion = reduceMotion || (zoomsDates && !canReuse && candidate == nil)
        if self.destination != nil {
            // 通用正文只保留当前混合结果；活动画布独立保留，跨页面淡化也不冻结其速度。
            drawingBodyOnly = !nextReducedMotion && (canReuse || (canvas != nil && candidate == nil))
            let image = CalendarSnapshotImage.capture(self, in: cardFrame)
            drawingBodyOnly = false
            guard let image else { return false }
            source = CalendarZoomSnapshot(content: image, size: NSSize(width: 320, height: height),
                                          card: cardFrame, anchors: [], month: previous.month)
        }
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
        CalendarSurface.contentColor.setFill()
        path.fill()
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
