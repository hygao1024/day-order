import AppKit
import Combine
import QuartzCore
import SwiftUI

struct CalendarZoomGlyph {
    let day: Int
    let frame: NSRect
    let font: NSFont
    let color: NSColor
    var circle = false
}

@MainActor
protocol CalendarZoomParticipant: NSView {
    var zoomHiddenDays: Set<Int> { get set }
    func zoomGlyphs(month: Int, in root: NSView) -> [CalendarZoomGlyph]
}

private struct CalendarZoomSnapshot {
    let content: NSImage
    let size: NSSize
    let card: NSRect
    let glyphs: [CalendarZoomGlyph]

    @MainActor static func capture(_ root: NSView, month: Int) -> Self? {
        let views = descendants(root)
        guard let scroll = views.compactMap({ $0 as? NSScrollView }).first,
              let contentBitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return nil }
        let card = root.convert(scroll.bounds, from: scroll)
        let headers = views.compactMap { $0 as? YearHeaderView }.filter { !$0.visibleRect.isEmpty }
            .map { root.convert($0.visibleRect, from: $0) }
        let participants = views.compactMap { $0 as? any CalendarZoomParticipant }
            .map { view in
                (view, view.zoomGlyphs(month: month, in: root).filter { glyph in
                    !headers.contains { $0.intersects(glyph.frame) }
                })
            }.filter { !$0.1.isEmpty }
        let glyphs = participants.flatMap(\.1)
        participants.forEach { view, days in view.zoomHiddenDays = Set(days.map(\.day)); view.needsDisplay = true }
        defer {
            participants.forEach { view, _ in view.zoomHiddenDays = []; view.needsDisplay = true }
        }
        scroll.cacheDisplay(in: scroll.bounds, to: contentBitmap)
        let content = NSImage(size: scroll.bounds.size)
        content.addRepresentation(contentBitmap)
        return Self(content: content, size: root.bounds.size, card: card, glyphs: glyphs)
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
    private var animationStarted = 0.0
    private var animationDuration = 0.22
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
    private(set) var frameMilliseconds: [Double] = []
    private(set) var drawingMilliseconds: [Double] = []
    var matchedDayCount: Int { overlay?.matchedDayCount ?? 0 }
    var movingDayFrame: NSRect? { overlay?.movingDayFrame }
    var movingCardFrame: NSRect? { overlay?.cardFrame }
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
            self?.prepare(year: year)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateMaterial() }
            .store(in: &subscriptions)
        model.$showingSettings.filter { $0 }.sink { [weak self] _ in self?.cancelTransition() }
            .store(in: &subscriptions)
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

    private func prepare(year: Bool) {
        // 新请求使旧动画失效；关闭状态和设置页不创建过渡。
        let interrupted = isTransitioning
        cancelTransition()
        guard !interrupted, view.window?.isVisible == true, !model.showingSettings else { return }
        #if DEBUG
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        displayTimestamps = []
        frameMilliseconds = []
        drawingMilliseconds = []
        #endif
        let parts = model.engine.calendar.dateComponents([.year, .month], from: model.month)
        let month = parts.year! * 100 + parts.month!
        guard let shell = descendants(host.view).compactMap({ $0 as? CalendarShellView }).first,
              let source = CalendarZoomSnapshot.capture(host.view, month: month) else { return }
        transitioningShell = shell
        let layer = CalendarZoomOverlay(source: source)
        layer.frame = view.bounds
        layer.appearance = host.view.effectiveAppearance
        view.addSubview(layer)
        overlay = layer
        shell.transitionCard = source.card
        shell.transitionHeight = source.size.height
        shell.content.alphaValue = 0
        let request = serial
        progress = 0
        elapsedFraction = 0
        preparation = Task { [weak self] in
            // 让发布属性完成赋值，随后主动刷新并布局；不额外等待一个固定时间片。
            await Task.yield()
            guard let self, serial == request, !Task.isCancelled else { return }
            defer {
                if serial == request {
                    preparation = nil
                    if displayLink == nil { finishTransition() }
                }
            }
            guard model.showingYearOverview == year, view.window?.isVisible == true else { return }
            // Published 在赋值前通知；快照可能消费旧页面的刷新，赋值后再通知视图读取新状态。
            model.objectWillChange.send()
            await Task.yield()
            guard serial == request, !Task.isCancelled else { return }
            targetSize = host.view.fittingSize
            host.view.frame = NSRect(origin: .zero, size: targetSize)
            host.view.layoutSubtreeIfNeeded()
            shell.content.alphaValue = 1
            let destination = CalendarZoomSnapshot.capture(host.view, month: month)
            shell.content.alphaValue = 0
            guard let destination else { return }
            layer.destination = destination
            var reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            #if DEBUG
            reduced = reduceMotionOverride ?? reduced
            #endif
            reduced = reduced || layer.matchedDayCount == 0
            layer.reducedMotion = reduced
            shell.beginAnimation()
            animationDuration = reduced ? 0.12 : 0.22
            animationStarted = CACurrentMediaTime()
            #if DEBUG
            preparationMilliseconds = (ProcessInfo.processInfo.systemUptime - preparationStarted) * 1000
            #endif
            applyFrame(time: 0)
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

    private func advance(_ link: CADisplayLink) {
        guard displayLink === link else { return }
        guard view.window?.isVisible == true else { finishTransition(); return }
        #if DEBUG
        let frameStarted = ProcessInfo.processInfo.systemUptime
        displayTimestamps.append(link.targetTimestamp)
        defer { frameMilliseconds.append((ProcessInfo.processInfo.systemUptime - frameStarted) * 1000) }
        #endif
        let time = min(1, max(elapsedFraction, (link.targetTimestamp - animationStarted) / animationDuration))
        applyFrame(time: time)
        if time == 1 { finishTransition() }
    }

    private func applyFrame(time: CGFloat) {
        guard let overlay, let destination = overlay.destination, let shell = transitioningShell else { return }
        elapsedFraction = time
        progress = overlay.reducedMotion ? time : 1 - pow(1 - time, 3)
        overlay.progress = progress
        let height = overlay.reducedMotion ? destination.size.height
            : overlay.source.size.height + (destination.size.height - overlay.source.size.height) * progress
        shell.updateTransition(card: overlay.cardFrame, height: height)
        let size = NSSize(width: 320, height: height)
        if preferredContentSize != size { preferredContentSize = size }
        overlay.needsDisplay = true
    }

    private func finishTransition() {
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

private final class CalendarZoomOverlay: NSView {
    #if DEBUG
    var drawingMilliseconds: [Double] = []
    #endif
    let source: CalendarZoomSnapshot
    var destination: CalendarZoomSnapshot? { didSet { prepareTracks() } }
    private struct Track {
        let source: CalendarZoomGlyph?
        let destination: CalendarZoomGlyph?
        let sourceWeight: CGFloat
        let destinationWeight: CGFloat

        init(source: CalendarZoomGlyph?, destination: CalendarZoomGlyph?) {
            self.source = source
            self.destination = destination
            func weight(_ glyph: CalendarZoomGlyph?) -> CGFloat {
                (glyph?.font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
            }
            sourceWeight = weight(source)
            destinationWeight = weight(destination)
        }
    }
    private var tracks: [Track] = []
    private(set) var matchedDayCount = 0
    var progress: CGFloat = 0
    var reducedMotion = false
    override var isFlipped: Bool { true }

    init(source: CalendarZoomSnapshot) {
        self.source = source
        super.init(frame: .zero)
        setAccessibilityElement(false)
        prepareTracks()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { cardFrame.contains(point) ? self : nil }

    private func prepareTracks() {
        let from = Dictionary(source.glyphs.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        let to = Dictionary((destination?.glyphs ?? []).map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        tracks = Set(from.keys).union(to.keys).sorted().map { Track(source: from[$0], destination: to[$0]) }
        matchedDayCount = tracks.filter { $0.source != nil && $0.destination != nil }.count
    }

    var movingDayFrame: NSRect? {
        guard let track = tracks.first(where: { $0.source != nil && $0.destination != nil }),
              let a = track.source, let b = track.destination else { return nil }
        return reducedMotion ? b.frame : interpolate(a.frame, b.frame, progress)
    }

    var cardFrame: NSRect {
        let target = destination?.card ?? source.card
        return reducedMotion ? target : interpolate(source.card, target, progress)
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        let drawingStarted = ProcessInfo.processInfo.systemUptime
        defer { drawingMilliseconds.append((ProcessInfo.processInfo.systemUptime - drawingStarted) * 1000) }
        #endif
        let destination = destination ?? source
        let p = progress
        let outgoing = reducedMotion ? 1 - p : max(0, 1 - p / 0.35)
        let incoming = reducedMotion ? p : max(0, (p - 0.45) / 0.55)
        let card = cardFrame
        CalendarSurface.contentColor.setFill()
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawImage(source, alpha: outgoing)
        drawImage(destination, alpha: incoming)
        NSGraphicsContext.restoreGraphicsState()
        for track in tracks {
            if let a = track.source, let b = track.destination, !reducedMotion {
                let rect = interpolate(a.frame, b.frame, p)
                let size = a.font.pointSize + (b.font.pointSize - a.font.pointSize) * p
                let weight = NSFont.Weight(rawValue: track.sourceWeight + (track.destinationWeight - track.sourceWeight) * p)
                let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                let color = a.color.blended(withFraction: p, of: b.color) ?? b.color
                let glyph = CalendarZoomGlyph(day: a.day, frame: rect, font: font, color: color, circle: a.circle && b.circle)
                drawGlyph(glyph, frame: rect, font: font, alpha: 1)
            } else {
                if let a = track.source { drawGlyph(a, frame: a.frame, font: a.font, alpha: outgoing) }
                if let b = track.destination { drawGlyph(b, frame: b.frame, font: b.font, alpha: incoming) }
            }
        }
    }

    private func drawImage(_ snapshot: CalendarZoomSnapshot, alpha: CGFloat) {
        snapshot.content.draw(in: snapshot.card, from: .zero, operation: .sourceOver,
                              fraction: alpha, respectFlipped: true, hints: nil)
    }

    private func drawGlyph(_ glyph: CalendarZoomGlyph, frame: NSRect, font: NSFont, alpha: CGFloat) {
        if glyph.circle {
            NSColor(srgbRed: 0.89, green: 0.20, blue: 0.15, alpha: alpha).setFill()
            let diameter = min(frame.width, frame.height)
            NSBezierPath(ovalIn: NSRect(x: frame.midX - diameter / 2, y: frame.midY - diameter / 2,
                                       width: diameter, height: diameter)).fill()
        }
        let text = NSAttributedString(string: String(glyph.day), attributes: [.font: font, .foregroundColor: glyph.color.withAlphaComponent(alpha)])
        let size = text.size()
        text.draw(at: NSPoint(x: frame.midX - size.width / 2,
                              y: frame.midY - size.height / 2))
    }

    private func interpolate(_ a: NSRect, _ b: NSRect, _ p: CGFloat) -> NSRect {
        NSRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
               width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
    }
}
