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

@MainActor
enum CalendarSnapshotImage {
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
    let glyphs: [CalendarZoomGlyph]
    let month: Int

    @MainActor static func capture(_ root: NSView, month: Int, includeGlyphs: Bool) -> Self? {
        let views = descendants(root)
        guard let scroll = views.compactMap({ $0 as? NSScrollView }).first,
              let contentBitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) else { return nil }
        let card = root.convert(scroll.bounds, from: scroll)
        let headers = views.compactMap { $0 as? YearHeaderView }.filter { !$0.visibleRect.isEmpty }
            .map { root.convert($0.visibleRect, from: $0) }
        let participants = (includeGlyphs ? views.compactMap { $0 as? any CalendarZoomParticipant } : [])
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
        return Self(content: content, size: root.bounds.size, card: card, glyphs: glyphs, month: month)
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
        model.timelineBuildMilliseconds = 0
        displayTimestamps = []
        frameMilliseconds = []
        drawingMilliseconds = []
        #endif
        let parts = model.engine.calendar.dateComponents([.year, .month], from: model.month)
        let month = parts.year! * 100 + parts.month!
        guard let shell = descendants(host.view).compactMap({ $0 as? CalendarShellView }).first else { return }
        if overlay == nil {
            guard let source = CalendarZoomSnapshot.capture(host.view, month: month, includeGlyphs: transition.zoomsDates) else { return }
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
            let destination = CalendarZoomSnapshot.capture(host.view, month: month, includeGlyphs: transition.zoomsDates)
            shell.content.alphaValue = 0
            guard let destination else { cancelTransition(); return }
            #if DEBUG
            preparationPhases["destinationMS"] = (ProcessInfo.processInfo.systemUptime - captureStarted) * 1000
            preparationPhases["timelineBuildMS"] = model.timelineBuildMilliseconds
            let oldCard = layer.cardFrame.animatableData
            let oldVelocity = layer.cardVelocity.animatableData
            let oldGlyphs = layer.glyphMotion
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
                for (id, old) in oldGlyphs {
                    guard let new = layer.glyphMotion[id] else { continue }
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

private final class CalendarZoomOverlay: NSView {
    #if DEBUG
    var drawingMilliseconds: [Double] = []
    var glyphMotion: [Int: (CGRect.AnimatableData, CGRect.AnimatableData)] {
        tracks.mapValues { ($0.frame.value.animatableData, $0.frame.velocity) }
    }
    #endif
    private var source: CalendarZoomSnapshot
    private(set) var destination: CalendarZoomSnapshot?
    private struct Track {
        let day: Int
        var frame: CalendarSpringValue<CGRect>
        var size: CalendarSpringValue<CGFloat>
        var weight: CalendarSpringValue<CGFloat>
        var color: NSColor
        var targetColor: NSColor
        var circle: Bool
        var opacity: CGFloat
        var startOpacity: CGFloat
        var targetOpacity: CGFloat

        init(_ glyph: CalendarZoomGlyph, opacity: CGFloat) {
            day = glyph.day
            frame = CalendarSpringValue(glyph.frame)
            size = CalendarSpringValue(glyph.font.pointSize)
            weight = CalendarSpringValue(Self.fontWeight(glyph.font))
            color = glyph.color
            targetColor = glyph.color
            circle = glyph.circle
            self.opacity = opacity
            startOpacity = opacity
            targetOpacity = opacity
        }

        static func fontWeight(_ font: NSFont) -> CGFloat {
            (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        }
    }
    private var tracks: [Int: Track] = [:]
    private var orderedDays: [Int] = []
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
        guard destination != nil else { return 0 }
        let t = min(1, elapsed / (reducedMotion ? 0.12 : 0.18))
        return t * t * (3 - 2 * t)
    }
    var height: CGFloat { windowHeight.value }
    var cardFrame: NSRect { card.value }
    var cardVelocity: NSRect {
        var rect = NSRect.zero
        rect.animatableData = card.velocity
        return rect
    }
    var movingDayFrame: NSRect? {
        orderedDays.compactMap { tracks[$0] }.first { $0.targetOpacity == 1 && (reducedMotion || $0.startOpacity > 0) }?.frame.value
    }
    var isSettled: Bool {
        guard contentFraction == 1 else { return false }
        return reducedMotion || (card.isSettled && windowHeight.isSettled && tracks.values.allSatisfy {
            $0.targetOpacity == 0 || ($0.frame.isSettled && $0.size.isSettled && $0.weight.isSettled)
        })
    }

    init(source: CalendarZoomSnapshot) {
        self.source = source
        card = CalendarSpringValue(source.card)
        windowHeight = CalendarSpringValue(source.size.height)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        for glyph in source.glyphs { tracks[source.month * 100 + glyph.day] = Track(glyph, opacity: 1) }
        orderedDays = tracks.keys.sorted()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { cardFrame.contains(point) ? self : nil }

    func retarget(_ destination: CalendarZoomSnapshot, duration: Double, reduceMotion: Bool, zoomsDates: Bool) -> Bool {
        let previousProgress = progress
        if self.destination != nil {
            // 只扁平化正文的混合图像；日期保留字形和速度，避免反向放大位图失真。
            drawingBodyOnly = true
            let image = CalendarSnapshotImage.capture(self, in: cardFrame)
            drawingBodyOnly = false
            guard let image else { return false }
            source = CalendarZoomSnapshot(content: image, size: NSSize(width: 320, height: height),
                                          card: cardFrame, glyphs: [], month: source.month)
        }
        let incoming = Dictionary(destination.glyphs.map { (destination.month * 100 + $0.day, $0) },
                                  uniquingKeysWith: { first, _ in first })
        matchedDayCount = incoming.keys.filter { (tracks[$0]?.opacity ?? 0) > 0 }.count
        reducedMotion = reduceMotion || (zoomsDates && matchedDayCount == 0)
        self.duration = reducedMotion ? 0.12 : duration
        spring = Spring(duration: duration, bounce: 0)
        tracks = tracks.filter { $0.value.opacity > 0.001 || incoming[$0.key] != nil }
        if reducedMotion {
            // 同一天在两端的位置也各自淡化，不能把旧数字瞬移到目标位置。
            for id in incoming.keys {
                if let outgoing = tracks.removeValue(forKey: id), outgoing.opacity > 0 {
                    tracks[-id] = outgoing
                }
            }
        }
        for id in Set(tracks.keys).union(incoming.keys) {
            var track = tracks[id] ?? Track(incoming[id]!, opacity: 0)
            track.color = track.color.blended(withFraction: previousProgress, of: track.targetColor) ?? track.targetColor
            track.startOpacity = track.opacity
            if let glyph = incoming[id] {
                track.frame.target = glyph.frame
                track.size.target = glyph.font.pointSize
                track.weight.target = Track.fontWeight(glyph.font)
                track.targetColor = glyph.color
                track.circle = glyph.circle
                track.targetOpacity = 1
            } else {
                track.targetOpacity = 0
            }
            if reducedMotion {
                // 短淡化不移动数字，离开的一端留在原处，进入的一端直接采用目标几何。
                if incoming[id] != nil {
                    track.frame = CalendarSpringValue(track.frame.target)
                    track.size = CalendarSpringValue(track.size.target)
                    track.weight = CalendarSpringValue(track.weight.target)
                }
            }
            tracks[id] = track
        }
        orderedDays = tracks.keys.sorted()
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
        }
        for id in orderedDays {
            guard var track = tracks[id] else { continue }
            if !reducedMotion {
                track.frame.advance(spring, by: deltaTime)
                track.size.advance(spring, by: deltaTime)
                track.weight.advance(spring, by: deltaTime)
            }
            track.opacity = track.startOpacity + (track.targetOpacity - track.startOpacity) * contentFraction
            tracks[id] = track
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        let drawingStarted = ProcessInfo.processInfo.systemUptime
        defer { drawingMilliseconds.append((ProcessInfo.processInfo.systemUptime - drawingStarted) * 1000) }
        #endif
        let destination = destination ?? source
        let path = NSBezierPath(roundedRect: cardFrame, xRadius: 12, yRadius: 12)
        CalendarSurface.contentColor.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        drawImage(source, alpha: 1 - contentFraction)
        drawImage(destination, alpha: contentFraction)
        NSGraphicsContext.restoreGraphicsState()
        guard !drawingBodyOnly else { return }
        for id in orderedDays {
            guard let track = tracks[id], track.opacity > 0 else { continue }
            let rect = track.frame.value
            let font = NSFont.monospacedDigitSystemFont(ofSize: track.size.value,
                                                       weight: NSFont.Weight(rawValue: track.weight.value))
            let color = track.color.blended(withFraction: progress, of: track.targetColor) ?? track.targetColor
            if track.circle {
                NSColor(srgbRed: 0.89, green: 0.20, blue: 0.15, alpha: track.opacity).setFill()
                let diameter = min(rect.width, rect.height)
                NSBezierPath(ovalIn: NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                           width: diameter, height: diameter)).fill()
            }
            let text = NSAttributedString(string: String(track.day), attributes: [.font: font,
                .foregroundColor: color.withAlphaComponent(track.opacity)])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }

    private func drawImage(_ snapshot: CalendarZoomSnapshot, alpha: CGFloat) {
        snapshot.content.draw(in: snapshot.card, from: .zero, operation: .sourceOver,
                              fraction: alpha, respectFlipped: true, hints: nil)
    }
}
